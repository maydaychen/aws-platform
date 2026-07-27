import Foundation
import SotoLambda

@MainActor
final class LambdaViewModel: ObservableObject {
    typealias FunctionLoader = () async throws -> [LambdaFunctionModel]

    @Published var functions: [LambdaFunctionModel] = []
    @Published var selectedFunction: LambdaFunctionModel?
    @Published var isLoading = false
    @Published var isCodeLoading = false
    @Published var error: String?
    @Published var searchText = ""

    private var provider: AWSServiceProvider?
    private var loadTask: Task<Void, Never>?
    private var codeLoadTask: Task<Void, Never>?
    private var functionLoader: FunctionLoader?

    init(functionLoader: FunctionLoader? = nil) {
        self.functionLoader = functionLoader
    }

    var filteredFunctions: [LambdaFunctionModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return functions }
        return functions.filter { function in
            [
                function.functionName,
                function.runtime,
                function.arn,
                function.handler,
                function.role,
                function.packageType
            ]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
            || function.tags.contains { key, value in
                key.lowercased().contains(query) || value.lowercased().contains(query)
            }
        }
    }

    func configure(provider: AWSServiceProvider) {
        self.provider = provider
        functionLoader = {
            let client = try await provider.lambdaClient()
            return try await Self.fetchFunctions(client: client)
        }
        loadTask?.cancel()
        codeLoadTask?.cancel()
        functions = []
        selectedFunction = nil
        refresh()
    }

    func refresh() {
        loadTask?.cancel()
        loadTask = Task { await loadFunctions() }
    }

    func cancelLoading() {
        loadTask?.cancel()
        codeLoadTask?.cancel()
        isLoading = false
        isCodeLoading = false
    }

    func reset() {
        cancelLoading()
        functions = []
        selectedFunction = nil
        error = nil
    }

    func loadFunctions() async {
        guard let functionLoader else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            functions = try await functionLoader()
            try Task.checkCancellation()

            if selectedFunction == nil {
                selectedFunction = functions.first
            }
        } catch {
            if error is CancellationError { return }
            functions = []
            selectedFunction = nil
            self.error = UserFacingError.message(for: error)
        }
    }

    func loadCodeForSelection() {
        guard let selectedFunction else { return }
        codeLoadTask?.cancel()
        codeLoadTask = Task { await loadCode(for: selectedFunction.functionName) }
    }

    func loadCode(for functionName: String) async {
        guard let provider, let index = functions.firstIndex(where: { $0.functionName == functionName }) else { return }
        isCodeLoading = true
        error = nil
        defer { isCodeLoading = false }

        do {
            let client = try await provider.lambdaClient()
            let response = try await client.getFunction(.init(functionName: functionName))

            var updated = functions[index]
            updated.arn = response.configuration?.functionArn
            updated.handler = response.configuration?.handler
            updated.role = response.configuration?.role
            updated.timeout = response.configuration?.timeout
            updated.codeSize = response.configuration?.codeSize
            updated.environment = response.configuration?.environment?.variables ?? updated.environment
            updated.vpcConfig = response.configuration?.vpcConfig?.vpcId
            updated.packageType = response.configuration?.packageType?.rawValue ?? updated.packageType
            updated.codeLocation = response.code?.location
            updated.imageUri = response.code?.imageUri
            updated.tags = response.tags ?? updated.tags

            if updated.packageType == "Image" {
                updated.codeFiles = [
                    LambdaCodeFile(
                        path: "Container Image",
                        content: updated.imageUri,
                        isBinary: true
                    )
                ]
            } else if let location = response.code?.location {
                updated.codeFiles = try await Self.downloadCodeFiles(from: location)
            }

            functions[index] = updated
            if selectedFunction?.functionName == functionName {
                selectedFunction = updated
            }
        } catch {
            if error is CancellationError { return }
            self.error = UserFacingError.message(for: error)
        }
    }

    private nonisolated static func downloadCodeFiles(from location: String) async throws -> [LambdaCodeFile] {
        guard let url = URL(string: location) else {
            throw LambdaCodeError.invalidDownloadURL
        }

        let (zipData, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw LambdaCodeError.downloadFailed((response as? HTTPURLResponse)?.statusCode)
        }
        try Task.checkCancellation()

        return try await Task.detached(priority: .userInitiated) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AWSPlatformLambdaCode", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let zipURL = root.appendingPathComponent("function.zip")
            let extractURL = root.appendingPathComponent("expanded", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            try FileManager.default.createDirectory(at: extractURL, withIntermediateDirectories: true)
            try zipData.write(to: zipURL, options: .atomic)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zipURL.path, extractURL.path]
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw LambdaCodeError.unzipFailed
            }

            return try readCodeFiles(in: extractURL)
        }.value
    }

    private nonisolated static func readCodeFiles(in directory: URL) throws -> [LambdaCodeFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [LambdaCodeFile] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            let fileSize = values.fileSize ?? 0
            let isText = isLikelyTextFile(fileURL)
            let content = isText && fileSize <= 200_000 ? try? String(contentsOf: fileURL, encoding: .utf8) : nil

            files.append(
                LambdaCodeFile(
                    path: relativePath,
                    content: content,
                    isBinary: content == nil
                )
            )
        }

        return files.sorted { $0.path < $1.path }
    }

    private nonisolated static func isLikelyTextFile(_ url: URL) -> Bool {
        let textExtensions: Set<String> = [
            "c", "conf", "cpp", "cs", "css", "go", "h", "html", "java", "js", "json",
            "jsx", "kt", "mjs", "php", "properties", "py", "rb", "rs", "sh", "swift",
            "toml", "ts", "tsx", "txt", "xml", "yaml", "yml"
        ]
        return textExtensions.contains(url.pathExtension.lowercased())
    }

    private static func fetchFunctions(client: Lambda) async throws -> [LambdaFunctionModel] {
        var rows: [LambdaFunctionModel] = []
        var marker: String?

        repeat {
            try Task.checkCancellation()
            let response = try await client.listFunctions(.init(marker: marker))
            rows.append(contentsOf: (response.functions ?? []).map { function in
                LambdaFunctionModel(
                    functionName: function.functionName ?? "unknown",
                    runtime: function.runtime?.rawValue,
                    lastModified: function.lastModified,
                    memorySize: function.memorySize,
                    arn: function.functionArn,
                    handler: function.handler,
                    role: function.role,
                    codeSize: function.codeSize,
                    timeout: function.timeout,
                    environment: function.environment?.variables ?? [:],
                    vpcConfig: function.vpcConfig?.vpcId,
                    packageType: function.packageType?.rawValue,
                    imageUri: nil,
                    tags: [:],
                    codeLocation: nil,
                    codeFiles: []
                )
            })
            marker = response.nextMarker
        } while marker != nil

        return rows
    }
}

enum LambdaCodeError: LocalizedError {
    case invalidDownloadURL
    case downloadFailed(Int?)
    case unzipFailed

    var errorDescription: String? {
        switch self {
        case .invalidDownloadURL:
            return "Lambda code download URL is invalid."
        case .downloadFailed(let statusCode):
            if let statusCode {
                return "Lambda code download failed with HTTP \(statusCode)."
            }
            return "Lambda code download failed."
        case .unzipFailed:
            return "Unable to unzip Lambda deployment package."
        }
    }
}
