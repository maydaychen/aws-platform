import Foundation
import SotoCore
import SotoLambda

@MainActor
final class LambdaViewModel: ObservableObject {
    typealias FunctionLoader = () async throws -> [LambdaFunctionModel]
    typealias DetailLoader = (String) async throws -> LambdaFunctionDetailModel
    typealias SummaryLoader = @Sendable (String) async throws -> LambdaFunctionSummary

    @Published var functions: [LambdaFunctionModel] = []
    @Published var selectedFunction: LambdaFunctionModel? {
        didSet {
            guard oldValue?.functionName != selectedFunction?.functionName else { return }
            loadDetailForSelection()
        }
    }
    @Published var functionDetail: LambdaFunctionDetailModel?
    @Published var isLoading = false
    @Published var isDetailLoading = false
    @Published var isCodeLoading = false
    @Published var error: String?
    @Published var summaryWarning: String?
    @Published var detailError: String?
    @Published var codeError: String?
    @Published var searchText = ""
    @Published var stateFilter = "All"
    @Published var packageFilter = "All"

    private var provider: AWSServiceProvider?
    private var loadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var codeLoadTask: Task<Void, Never>?
    private var functionLoader: FunctionLoader?
    private var detailLoader: DetailLoader?
    private var summaryLoader: SummaryLoader?
    private var listGeneration = 0

    init(
        functionLoader: FunctionLoader? = nil,
        detailLoader: DetailLoader? = nil,
        summaryLoader: SummaryLoader? = nil
    ) {
        self.functionLoader = functionLoader
        self.detailLoader = detailLoader
        self.summaryLoader = summaryLoader
    }

    var availableStates: [String] {
        ["All"] + Set(functions.compactMap(\.state)).sorted()
    }

    var availablePackageTypes: [String] {
        ["All"] + Set(functions.compactMap(\.packageType)).sorted()
    }

    var filteredFunctions: [LambdaFunctionModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return functions.filter { function in
            let matchesState = stateFilter == "All" || function.state == stateFilter
            let matchesPackage = packageFilter == "All" || function.packageType == packageFilter
            let matchesSearch = query.isEmpty || [
                function.functionName,
                function.runtime,
                function.state,
                function.lastUpdateStatus,
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
            return matchesState && matchesPackage && matchesSearch
        }
    }

    func configure(provider: AWSServiceProvider, refreshImmediately: Bool = true) {
        reset()
        self.provider = provider
        functionLoader = {
            let client = try await provider.lambdaClient()
            return try await Self.fetchFunctions(client: client)
        }
        summaryLoader = { name in
            let client = try await provider.lambdaClient()
            let response = try await client.getFunction(.init(functionName: name))
            guard let configuration = response.configuration else {
                throw LambdaDetailError.missingConfiguration
            }
            return LambdaFunctionSummary(
                state: configuration.state?.rawValue,
                lastUpdateStatus: configuration.lastUpdateStatus?.rawValue,
                tags: response.tags ?? [:]
            )
        }
        detailLoader = { functionName in
            let client = try await provider.lambdaClient()
            return try await Self.fetchDetail(functionName: functionName, client: client)
        }
        if refreshImmediately { refresh() }
    }

    func refresh() {
        loadTask?.cancel()
        loadTask = Task { await loadFunctions() }
    }

    func cancelLoading() {
        listGeneration += 1
        loadTask?.cancel()
        detailTask?.cancel()
        codeLoadTask?.cancel()
        isLoading = false
        isDetailLoading = false
        isCodeLoading = false
    }

    func reset() {
        cancelLoading()
        provider = nil
        functions = []
        selectedFunction = nil
        functionDetail = nil
        error = nil
        summaryWarning = nil
        detailError = nil
        codeError = nil
        stateFilter = "All"
        packageFilter = "All"
    }

    func loadFunctions() async {
        guard !Task.isCancelled, let functionLoader else { return }
        listGeneration += 1
        let generation = listGeneration
        isLoading = true
        error = nil
        summaryWarning = nil
        defer {
            if generation == listGeneration { isLoading = false }
        }

        do {
            var loadedFunctions = try await functionLoader()
            try Task.checkCancellation()
            guard generation == listGeneration else { return }

            if let summaryLoader {
                let results = try await Self.fetchSummaries(
                    names: loadedFunctions.map(\.functionName), loader: summaryLoader
                )
                try Task.checkCancellation()
                guard generation == listGeneration else { return }
                loadedFunctions = loadedFunctions.map { function in
                    var updated = function
                    if let summary = results[function.functionName] {
                        updated.state = summary.state
                        updated.lastUpdateStatus = summary.lastUpdateStatus
                        updated.tags = summary.tags
                    }
                    return updated
                }
                let unavailable = loadedFunctions.count - results.count
                if unavailable > 0 {
                    summaryWarning = "Status and tags unavailable for \(unavailable) function(s). Check lambda:GetFunction permission, then refresh. State filters exclude functions with unknown status."
                }
            }

            let selectedName = selectedFunction?.functionName
            functions = loadedFunctions
            selectedFunction = selectedName.flatMap { name in
                loadedFunctions.first { $0.functionName == name }
            } ?? loadedFunctions.first
            if selectedName == selectedFunction?.functionName {
                loadDetailForSelection()
            }

            if !availableStates.contains(stateFilter) {
                stateFilter = "All"
            }
            if !availablePackageTypes.contains(packageFilter) {
                packageFilter = "All"
            }
        } catch {
            guard generation == listGeneration, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            functions = []
            selectedFunction = nil
            self.error = UserFacingError.message(for: error)
        }
    }

    func loadDetailForSelection() {
        detailTask?.cancel()
        codeLoadTask?.cancel()
        functionDetail = nil
        detailError = nil
        codeError = nil
        isCodeLoading = false

        guard let functionName = selectedFunction?.functionName, detailLoader != nil else {
            isDetailLoading = false
            return
        }

        isDetailLoading = true
        detailTask = Task { await loadDetail(functionName: functionName) }
    }

    func loadDetail(functionName: String) async {
        guard let detailLoader else { return }

        do {
            let detail = try await detailLoader(functionName)
            try Task.checkCancellation()
            guard selectedFunction?.functionName == functionName else { return }
            functionDetail = detail
            if let index = functions.firstIndex(where: { $0.functionName == functionName }) {
                functions[index].state = detail.state
                functions[index].lastUpdateStatus = detail.lastUpdateStatus
                functions[index].tags = detail.tags
                selectedFunction = functions[index]
            }
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            guard selectedFunction?.functionName == functionName else { return }
            detailError = UserFacingError.message(for: error)
        }

        if selectedFunction?.functionName == functionName {
            isDetailLoading = false
        }
    }

    private nonisolated static func fetchSummaries(
        names: [String],
        loader: @escaping SummaryLoader
    ) async throws -> [String: LambdaFunctionSummary] {
        try await withThrowingTaskGroup(of: (String, LambdaFunctionSummary?).self) { group in
            var remaining = names.makeIterator()
            func enqueue(_ name: String) {
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        return (name, try await loader(name))
                    } catch {
                        try Task.checkCancellation()
                        if error is CancellationError { throw error }
                        return (name, nil)
                    }
                }
            }
            for _ in 0..<4 {
                if let name = remaining.next() { enqueue(name) }
            }
            var summaries: [String: LambdaFunctionSummary] = [:]
            while let (name, summary) = try await group.next() {
                try Task.checkCancellation()
                summaries[name] = summary
                if let next = remaining.next() { enqueue(next) }
            }
            return summaries
        }
    }

    func loadCodeForSelection() {
        guard let selectedFunction else { return }
        codeLoadTask?.cancel()
        codeError = nil
        codeLoadTask = Task { await loadCode(for: selectedFunction.functionName) }
    }

    func loadCode(for functionName: String) async {
        guard let provider else { return }
        isCodeLoading = true
        codeError = nil
        defer {
            if selectedFunction?.functionName == functionName {
                isCodeLoading = false
            }
        }

        do {
            let client = try await provider.lambdaClient()
            let response = try await client.getFunction(.init(functionName: functionName))
            try Task.checkCancellation()

            guard var updated = functions.first(where: { $0.functionName == functionName }) else {
                return
            }
            updated.arn = response.configuration?.functionArn
            updated.runtime = response.configuration?.runtime?.rawValue
            updated.state = response.configuration?.state?.rawValue
            updated.lastUpdateStatus = response.configuration?.lastUpdateStatus?.rawValue
            updated.handler = response.configuration?.handler
            updated.role = response.configuration?.role
            updated.timeout = response.configuration?.timeout
            updated.memorySize = response.configuration?.memorySize
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

            try Task.checkCancellation()
            guard let index = functions.firstIndex(where: { $0.functionName == functionName }),
                  selectedFunction?.functionName == functionName else {
                return
            }
            functions[index] = updated
            selectedFunction = updated
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            guard selectedFunction?.functionName == functionName else { return }
            codeError = UserFacingError.message(for: error)
        }
    }

    private nonisolated static func downloadCodeFiles(
        from location: String
    ) async throws -> [LambdaCodeFile] {
        guard let url = URL(string: location) else {
            throw LambdaCodeError.invalidDownloadURL
        }

        let (zipData, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw LambdaCodeError.downloadFailed((response as? HTTPURLResponse)?.statusCode)
        }
        try Task.checkCancellation()

        let extractionTask = Task.detached(priority: .userInitiated) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AWSPlatformLambdaCode", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let zipURL = root.appendingPathComponent("function.zip")
            let extractURL = root.appendingPathComponent("expanded", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: extractURL, withIntermediateDirectories: true)
            try zipData.write(to: zipURL, options: .atomic)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zipURL.path, extractURL.path]
            try process.run()
            process.waitUntilExit()

            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw LambdaCodeError.unzipFailed
            }

            return try readCodeFiles(in: extractURL)
        }

        return try await withTaskCancellationHandler {
            try await extractionTask.value
        } onCancel: {
            extractionTask.cancel()
        }
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
            try Task.checkCancellation()
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: directory.path + "/", with: "")
            let fileSize = values.fileSize ?? 0
            let isText = isLikelyTextFile(fileURL)
            let content = isText && fileSize <= 200_000
                ? try? String(contentsOf: fileURL, encoding: .utf8)
                : nil

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
        let configurations: [Lambda.FunctionConfiguration] = try await LambdaPaginator.collect { marker in
            let response = try await client.listFunctions(.init(marker: marker))
            return (response.functions ?? [], response.nextMarker)
        }

        return configurations.map { function in
            LambdaFunctionModel(
                functionName: function.functionName ?? "unknown",
                runtime: function.runtime?.rawValue,
                state: function.state?.rawValue,
                lastUpdateStatus: function.lastUpdateStatus?.rawValue,
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
        }
    }

    private static func fetchDetail(
        functionName: String,
        client: Lambda
    ) async throws -> LambdaFunctionDetailModel {
        let response = try await client.getFunction(.init(functionName: functionName))
        guard let configuration = response.configuration else {
            throw LambdaDetailError.missingConfiguration
        }

        var warnings: [String] = []
        if let tagsError = response.tagsError {
            warnings.append("Tags: \(tagsError.errorCode): \(tagsError.message)")
        }
        if let error = configuration.environment?.error {
            warnings.append(
                "Environment: \(error.errorCode ?? "Unknown"): \(error.message ?? "Unable to load variables.")"
            )
        }
        if let error = configuration.runtimeVersionConfig?.error {
            warnings.append(
                "Runtime version: \(error.errorCode ?? "Unknown"): \(error.message ?? "Unable to load runtime version.")"
            )
        }
        if let error = configuration.imageConfigResponse?.error {
            warnings.append(
                "Image config: \(error.errorCode ?? "Unknown"): \(error.message ?? "Unable to load image configuration.")"
            )
        }

        let eventSources: [LambdaEventSourceModel]
        do {
            eventSources = try await fetchEventSources(functionName: functionName, client: client)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            eventSources = []
            warnings.append("Event sources: \(UserFacingError.message(for: error))")
        }

        try Task.checkCancellation()
        let asyncConfigs: [LambdaAsyncInvokeConfigModel]
        do {
            asyncConfigs = try await fetchAsyncInvokeConfigs(
                functionName: functionName,
                client: client
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            asyncConfigs = []
            warnings.append("Async invoke configs: \(UserFacingError.message(for: error))")
        }

        try Task.checkCancellation()
        let functionURLs: [LambdaFunctionURLModel]
        do {
            functionURLs = try await fetchFunctionURLs(functionName: functionName, client: client)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            functionURLs = []
            warnings.append("Function URLs: \(UserFacingError.message(for: error))")
        }

        try Task.checkCancellation()
        let versions: [LambdaVersionModel]
        do {
            versions = try await fetchVersions(functionName: functionName, client: client)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            versions = []
            warnings.append("Versions: \(UserFacingError.message(for: error))")
        }

        try Task.checkCancellation()
        let aliases: [LambdaAliasModel]
        do {
            aliases = try await fetchAliases(functionName: functionName, client: client)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            aliases = []
            warnings.append("Aliases: \(UserFacingError.message(for: error))")
        }

        try Task.checkCancellation()
        let provisionedConcurrency: [LambdaProvisionedConcurrencyModel]
        do {
            provisionedConcurrency = try await fetchProvisionedConcurrency(
                functionName: functionName,
                client: client
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            provisionedConcurrency = []
            warnings.append("Provisioned concurrency: \(UserFacingError.message(for: error))")
        }

        try Task.checkCancellation()
        var policyRevisionId: String?
        let policyStatements: [LambdaPolicyStatementModel]
        do {
            let policy = try await client.getPolicy(.init(functionName: functionName))
            policyRevisionId = policy.revisionId
            if let policyDocument = policy.policy {
                policyStatements = try LambdaPolicyParser.parse(policyDocument)
            } else {
                policyStatements = []
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            policyStatements = []
            if errorCode(error) != "ResourceNotFoundException" {
                warnings.append("Resource policy: \(UserFacingError.message(for: error))")
            }
        }

        let imageConfig = configuration.imageConfigResponse?.imageConfig
        return LambdaFunctionDetailModel(
            functionName: functionName,
            description: configuration.description,
            state: configuration.state?.rawValue,
            stateReason: configuration.stateReason,
            stateReasonCode: configuration.stateReasonCode?.rawValue,
            lastUpdateStatus: configuration.lastUpdateStatus?.rawValue,
            lastUpdateStatusReason: configuration.lastUpdateStatusReason,
            lastUpdateStatusReasonCode: configuration.lastUpdateStatusReasonCode?.rawValue,
            version: configuration.version,
            architectures: configuration.architectures?.map(\.rawValue) ?? [],
            runtimeVersionARN: configuration.runtimeVersionConfig?.runtimeVersionArn,
            revisionId: configuration.revisionId,
            codeSHA256: configuration.codeSha256,
            configSHA256: configuration.configSha256,
            ephemeralStorageMB: configuration.ephemeralStorage?.size,
            environment: configuration.environment?.variables ?? [:],
            environmentError: configuration.environment?.error?.message,
            vpcId: configuration.vpcConfig?.vpcId,
            subnetIds: configuration.vpcConfig?.subnetIds ?? [],
            securityGroupIds: configuration.vpcConfig?.securityGroupIds ?? [],
            ipv6AllowedForDualStack: configuration.vpcConfig?.ipv6AllowedForDualStack,
            layers: (configuration.layers ?? []).compactMap { layer in
                guard let arn = layer.arn else { return nil }
                return LambdaLayerModel(
                    arn: arn,
                    codeSize: layer.codeSize,
                    signingJobARN: layer.signingJobArn,
                    signingProfileVersionARN: layer.signingProfileVersionArn
                )
            },
            fileSystems: (configuration.fileSystemConfigs ?? []).map {
                LambdaFileSystemModel(arn: $0.arn, localMountPath: $0.localMountPath)
            },
            deadLetterTargetARN: configuration.deadLetterConfig?.targetArn,
            tracingMode: configuration.tracingConfig?.mode?.rawValue,
            logGroup: configuration.loggingConfig?.logGroup,
            logFormat: configuration.loggingConfig?.logFormat?.rawValue,
            applicationLogLevel: configuration.loggingConfig?.applicationLogLevel?.rawValue,
            systemLogLevel: configuration.loggingConfig?.systemLogLevel?.rawValue,
            kmsKeyARN: configuration.kmsKeyArn,
            sourceKMSKeyARN: response.code?.sourceKMSKeyArn,
            snapStartApplyOn: configuration.snapStart?.applyOn?.rawValue,
            snapStartOptimizationStatus: configuration.snapStart?.optimizationStatus?.rawValue,
            imageEntryPoint: imageConfig?.entryPoint ?? [],
            imageCommand: imageConfig?.command ?? [],
            imageWorkingDirectory: imageConfig?.workingDirectory,
            codeLocation: response.code?.location,
            imageURI: response.code?.imageUri,
            resolvedImageURI: response.code?.resolvedImageUri,
            repositoryType: response.code?.repositoryType,
            reservedConcurrency: response.concurrency?.reservedConcurrentExecutions,
            tags: response.tags ?? [:],
            eventSources: eventSources,
            asyncInvokeConfigs: asyncConfigs,
            functionURLs: functionURLs,
            versions: versions,
            aliases: aliases,
            provisionedConcurrency: provisionedConcurrency,
            policyRevisionId: policyRevisionId,
            policyStatements: policyStatements,
            warnings: warnings
        )
    }

    private static func fetchEventSources(
        functionName: String,
        client: Lambda
    ) async throws -> [LambdaEventSourceModel] {
        let mappings: [Lambda.EventSourceMappingConfiguration] = try await LambdaPaginator.collect { marker in
            let response = try await client.listEventSourceMappings(
                .init(functionName: functionName, marker: marker)
            )
            return (response.eventSourceMappings ?? [], response.nextMarker)
        }

        return mappings.enumerated().map { index, mapping in
            let source = mapping.eventSourceArn
                ?? mapping.queues?.joined(separator: ", ")
                ?? mapping.topics?.joined(separator: ", ")
            return LambdaEventSourceModel(
                uuid: mapping.uuid
                    ?? mapping.eventSourceMappingArn
                    ?? "\(source ?? "event-source")-\(index)",
                type: eventSourceType(source),
                sourceARN: source,
                state: mapping.state,
                stateTransitionReason: mapping.stateTransitionReason,
                batchSize: mapping.batchSize,
                batchingWindowSeconds: mapping.maximumBatchingWindowInSeconds,
                parallelizationFactor: mapping.parallelizationFactor,
                maximumRetryAttempts: mapping.maximumRetryAttempts,
                maximumRecordAgeSeconds: mapping.maximumRecordAgeInSeconds,
                startingPosition: mapping.startingPosition?.rawValue,
                bisectBatchOnError: mapping.bisectBatchOnFunctionError,
                lastProcessingResult: mapping.lastProcessingResult,
                onFailureDestination: mapping.destinationConfig?.onFailure?.destination
            )
        }
    }

    private static func fetchAsyncInvokeConfigs(
        functionName: String,
        client: Lambda
    ) async throws -> [LambdaAsyncInvokeConfigModel] {
        let configs: [Lambda.FunctionEventInvokeConfig] = try await LambdaPaginator.collect { marker in
            let response = try await client.listFunctionEventInvokeConfigs(
                .init(functionName: functionName, marker: marker)
            )
            return (response.functionEventInvokeConfigs ?? [], response.nextMarker)
        }

        return configs.compactMap { config in
            guard let functionARN = config.functionArn else { return nil }
            return LambdaAsyncInvokeConfigModel(
                functionARN: functionARN,
                qualifier: qualifier(from: functionARN, functionName: functionName),
                maximumEventAgeSeconds: config.maximumEventAgeInSeconds,
                maximumRetryAttempts: config.maximumRetryAttempts,
                onSuccessDestination: config.destinationConfig?.onSuccess?.destination,
                onFailureDestination: config.destinationConfig?.onFailure?.destination,
                lastModified: config.lastModified
            )
        }
    }

    private static func fetchFunctionURLs(
        functionName: String,
        client: Lambda
    ) async throws -> [LambdaFunctionURLModel] {
        let configurations: [Lambda.FunctionUrlConfig] = try await LambdaPaginator.collect { marker in
            let response = try await client.listFunctionUrlConfigs(
                .init(functionName: functionName, marker: marker)
            )
            return (response.functionUrlConfigs, response.nextMarker)
        }

        return configurations.map { config in
            LambdaFunctionURLModel(
                functionARN: config.functionArn,
                url: config.functionUrl,
                authType: config.authType.rawValue,
                invokeMode: config.invokeMode?.rawValue,
                creationTime: config.creationTime,
                lastModifiedTime: config.lastModifiedTime,
                allowCredentials: config.cors?.allowCredentials,
                allowedOrigins: config.cors?.allowOrigins ?? [],
                allowedMethods: config.cors?.allowMethods ?? []
            )
        }
    }

    private static func fetchVersions(
        functionName: String,
        client: Lambda
    ) async throws -> [LambdaVersionModel] {
        let configurations: [Lambda.FunctionConfiguration] = try await LambdaPaginator.collect { marker in
            let response = try await client.listVersionsByFunction(
                .init(functionName: functionName, marker: marker)
            )
            return (response.versions ?? [], response.nextMarker)
        }

        return configurations.map { version in
            LambdaVersionModel(
                version: version.version ?? "unknown",
                state: version.state?.rawValue,
                runtime: version.runtime?.rawValue,
                architectures: version.architectures?.map(\.rawValue) ?? [],
                description: version.description,
                lastModified: version.lastModified,
                codeSize: version.codeSize,
                memorySize: version.memorySize,
                timeout: version.timeout
            )
        }
    }

    private static func fetchAliases(
        functionName: String,
        client: Lambda
    ) async throws -> [LambdaAliasModel] {
        let configurations: [Lambda.AliasConfiguration] = try await LambdaPaginator.collect { marker in
            let response = try await client.listAliases(
                .init(functionName: functionName, marker: marker)
            )
            return (response.aliases ?? [], response.nextMarker)
        }

        return configurations.compactMap { alias in
            guard let name = alias.name else { return nil }
            return LambdaAliasModel(
                name: name,
                functionVersion: alias.functionVersion,
                description: alias.description,
                revisionId: alias.revisionId,
                additionalVersionWeights: alias.routingConfig?.additionalVersionWeights ?? [:]
            )
        }
    }

    private static func fetchProvisionedConcurrency(
        functionName: String,
        client: Lambda
    ) async throws -> [LambdaProvisionedConcurrencyModel] {
        let configurations: [Lambda.ProvisionedConcurrencyConfigListItem] =
            try await LambdaPaginator.collect { marker in
                let response = try await client.listProvisionedConcurrencyConfigs(
                    .init(functionName: functionName, marker: marker)
                )
                return (response.provisionedConcurrencyConfigs ?? [], response.nextMarker)
            }

        return configurations.compactMap { config in
            guard let functionARN = config.functionArn else { return nil }
            return LambdaProvisionedConcurrencyModel(
                functionARN: functionARN,
                qualifier: qualifier(from: functionARN, functionName: functionName),
                requested: config.requestedProvisionedConcurrentExecutions,
                allocated: config.allocatedProvisionedConcurrentExecutions,
                available: config.availableProvisionedConcurrentExecutions,
                status: config.status?.rawValue,
                statusReason: config.statusReason,
                lastModified: config.lastModified
            )
        }
    }

    private static func eventSourceType(_ source: String?) -> String {
        guard let source = source?.lowercased() else { return "Other" }
        if source.contains(":sqs:") { return "SQS" }
        if source.contains(":kinesis:") { return "Kinesis" }
        if source.contains(":dynamodb:") { return "DynamoDB Streams" }
        if source.contains(":kafka:") { return "MSK / Kafka" }
        if source.contains(":mq:") { return "Amazon MQ" }
        if source.contains(":rds:") || source.contains(":docdb:") {
            return "DocumentDB"
        }
        return "Other"
    }

    private static func qualifier(from arn: String, functionName: String) -> String {
        let components = arn.split(separator: ":").map(String.init)
        guard let nameIndex = components.lastIndex(of: functionName),
              nameIndex + 1 < components.count else {
            return "$LATEST"
        }
        return components[nameIndex + 1]
    }

    private static func errorCode(_ error: Error) -> String? {
        if let error = error as? LambdaErrorType {
            return error.errorCode
        }
        if let error = error as? AWSResponseError {
            return error.errorCode
        }
        if let error = error as? AWSErrorType {
            return error.errorCode
        }
        return nil
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

private enum LambdaDetailError: LocalizedError {
    case missingConfiguration

    var errorDescription: String? {
        "The selected Lambda function configuration is unavailable."
    }
}

@MainActor
enum LambdaPaginator {
    static func collect<Item>(
        _ loadPage: (String?) async throws -> ([Item], String?)
    ) async throws -> [Item] {
        var result: [Item] = []
        var marker: String?

        repeat {
            try Task.checkCancellation()
            let page = try await loadPage(marker)
            result += page.0
            marker = page.1
        } while marker != nil

        return result
    }
}
