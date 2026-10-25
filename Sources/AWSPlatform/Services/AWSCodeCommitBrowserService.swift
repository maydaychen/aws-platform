import Foundation
import SotoCodeCommit
import SotoCore

struct AWSCodeCommitBrowserService: Sendable {
    typealias RepositoryLoader = @Sendable (CodeCommit.GetRepositoryInput) async throws -> CodeCommit.GetRepositoryOutput
    typealias FolderLoader = @Sendable (CodeCommit.GetFolderInput) async throws -> CodeCommit.GetFolderOutput
    typealias FileLoader = @Sendable (CodeCommit.GetFileInput) async throws -> CodeCommit.GetFileOutput
    typealias DifferencesLoader = @Sendable (CodeCommit.GetDifferencesInput) async throws -> CodeCommit.GetDifferencesOutput
    typealias PullRequestsLoader = @Sendable (CodeCommit.ListPullRequestsInput) async throws -> CodeCommit.ListPullRequestsOutput
    typealias PullRequestLoader = @Sendable (CodeCommit.GetPullRequestInput) async throws -> CodeCommit.GetPullRequestOutput

    private struct Operations: Sendable {
        let repository: RepositoryLoader
        let folder: FolderLoader
        let file: FileLoader
        let differences: DifferencesLoader
        let pullRequests: PullRequestsLoader
        let pullRequest: PullRequestLoader
    }
    private let provider: AWSServiceProvider?
    private let injected: Operations?

    init(provider: AWSServiceProvider) { self.provider = provider; injected = nil }

    init(repositoryLoader: @escaping RepositoryLoader, folderLoader: @escaping FolderLoader,
         fileLoader: @escaping FileLoader, differencesLoader: @escaping DifferencesLoader,
         pullRequestsLoader: @escaping PullRequestsLoader, pullRequestLoader: @escaping PullRequestLoader) {
        provider = nil
        injected = Operations(repository: repositoryLoader, folder: folderLoader, file: fileLoader,
                              differences: differencesLoader, pullRequests: pullRequestsLoader, pullRequest: pullRequestLoader)
    }

    func loadFolder(scope: MonitoringScope, repository: CodeCommitRepository, commit: String,
                    path: String) async throws -> CodeCommitFolder {
        do {
            guard Self.validSHA(commit), Self.validPath(path) else { throw CodeCommitBrowserError.invalidInput }
            let operations = try await operations(scope: scope, repository: repository)
            let raw = try await operations.folder(.init(commitSpecifier: commit, folderPath: path, repositoryName: repository.name))
            try Task.checkCancellation()
            guard raw.commitId == commit, CodeCommitPath.matches(raw.folderPath, path),
                  raw.treeId.map(Self.validSHA) ?? true else { throw CodeCommitBrowserError.invalidResponse }
            var entries: [CodeCommitTreeEntry] = []
            func append(_ pathValue: String?, _ relative: String?, _ objectID: String?, _ kind: CodeCommitEntryKind) throws {
                guard let pathValue, Self.validPath(pathValue, rootAllowed: false), CodeCommitPath.matches(Self.parent(of: pathValue), path),
                      let objectID, Self.validSHA(objectID),
                      relative.map({ CodeCommitPath.matches($0, Self.name(of: pathValue)) }) ?? true else {
                    throw CodeCommitBrowserError.invalidResponse
                }
                entries.append(.init(path: pathValue, kind: kind, objectID: objectID))
            }
            for row in raw.subFolders ?? [] { try append(row.absolutePath, row.relativePath, row.treeId, .folder) }
            for row in raw.files ?? [] { try append(row.absolutePath, row.relativePath, row.blobId, .file) }
            for row in raw.symbolicLinks ?? [] { try append(row.absolutePath, row.relativePath, row.blobId, .symbolicLink) }
            for row in raw.subModules ?? [] { try append(row.absolutePath, row.relativePath, row.commitId, .submodule) }
            guard entries.count <= 10_000, Set(entries.map(\.id)).count == entries.count else {
                throw CodeCommitBrowserError.invalidResponse
            }
            return .init(commitID: commit, path: path, entries: entries.sorted {
                if ($0.kind == .folder) != ($1.kind == .folder) { return $0.kind == .folder }
                return CodeCommitPath.precedes($0.path, $1.path)
            })
        } catch { throw Self.sanitized(error) }
    }

    func loadFile(scope: MonitoringScope, repository: CodeCommitRepository, commit: String, path: String,
                  expectedBlob: String? = nil) async throws -> CodeCommitFilePreview {
        do {
            guard Self.validSHA(commit), Self.validPath(path, rootAllowed: false),
                  expectedBlob.map(Self.validSHA) ?? true else { throw CodeCommitBrowserError.invalidInput }
            let operations = try await operations(scope: scope, repository: repository)
            let raw = try await operations.file(.init(commitSpecifier: commit, filePath: path, repositoryName: repository.name))
            try Task.checkCancellation()
            guard raw.commitId == commit, CodeCommitPath.matches(raw.filePath, path), Self.validSHA(raw.blobId), raw.fileSize >= 0,
                  expectedBlob.map({ $0 == raw.blobId }) ?? true else { throw CodeCommitBrowserError.invalidResponse }
            let preview: CodeCommitPreview
            if raw.fileSize > CodeCommitPreview.maximumBytes {
                preview = .tooLarge
            } else {
                guard raw.fileContent.base64count <= ((CodeCommitPreview.maximumBytes + 2) / 3) * 4,
                      let decoded = raw.fileContent.decoded(), decoded.count == raw.fileSize else {
                    throw CodeCommitBrowserError.invalidResponse
                }
                preview = .make(data: Data(decoded))
            }
            return .init(commitID: commit, path: path, blobID: raw.blobId, byteCount: raw.fileSize, preview: preview)
        } catch { throw Self.sanitized(error) }
    }

    func loadDifferences(scope: MonitoringScope, repository: CodeCommitRepository, before: String?,
                         after: String) async throws -> [CodeCommitFileChange] {
        do {
            guard Self.validSHA(after), before.map(Self.validSHA) ?? true else { throw CodeCommitBrowserError.invalidInput }
            let operations = try await operations(scope: scope, repository: repository)
            let rows: [CodeCommitFileChange] = try await Self.pages { token in
                let raw = try await operations.differences(.init(afterCommitSpecifier: after, beforeCommitSpecifier: before,
                                                               maxResults: 100, nextToken: token, repositoryName: repository.name))
                let values = try (raw.differences ?? []).map { row -> CodeCommitFileChange in
                    func blob(_ raw: CodeCommit.BlobMetadata?) throws -> CodeCommitChangeBlob? {
                        guard let raw else { return nil }
                        guard let id = raw.blobId, Self.validSHA(id), let path = raw.path else {
                            throw CodeCommitBrowserError.invalidResponse
                        }
                        let normalized = path.utf8.first == 47 ? path : "/" + path
                        guard Self.validPath(normalized, rootAllowed: false) else { throw CodeCommitBrowserError.invalidResponse }
                        return .init(id: id, path: normalized, mode: raw.mode)
                    }
                    let before = try blob(row.beforeBlob), after = try blob(row.afterBlob)
                    guard let type = row.changeType?.rawValue,
                          (type == "A" && before == nil && after != nil) ||
                          (type == "D" && before != nil && after == nil) ||
                          (type == "M" && before != nil && after != nil) else { throw CodeCommitBrowserError.invalidResponse }
                    return .init(type: type, before: before, after: after)
                }
                return (values, raw.nextToken)
            }
            guard Set(rows.map(\.id)).count == rows.count else { throw CodeCommitBrowserError.invalidResponse }
            return rows.sorted { CodeCommitPath.precedes($0.path, $1.path) }
        } catch { throw Self.sanitized(error) }
    }

    func loadPullRequests(scope: MonitoringScope, repository: CodeCommitRepository, status: String?) async throws -> [String] {
        do {
            guard status == nil || ["OPEN", "CLOSED"].contains(status ?? "") else { throw CodeCommitBrowserError.invalidInput }
            let operations = try await operations(scope: scope, repository: repository)
            let ids: [String] = try await Self.pages { token in
                let raw = try await operations.pullRequests(.init(maxResults: 100, nextToken: token,
                    pullRequestStatus: status.flatMap(CodeCommit.PullRequestStatusEnum.init(rawValue:)), repositoryName: repository.name))
                guard raw.pullRequestIds.allSatisfy(Self.validPullRequestID) else { throw CodeCommitBrowserError.invalidResponse }
                return (raw.pullRequestIds, raw.nextToken)
            }
            guard Set(ids).count == ids.count else { throw CodeCommitBrowserError.invalidResponse }
            return ids
        } catch { throw Self.sanitized(error) }
    }

    func loadPullRequest(scope: MonitoringScope, repository: CodeCommitRepository, id: String) async throws -> CodeCommitPullRequest {
        do {
            guard Self.validPullRequestID(id) else { throw CodeCommitBrowserError.invalidInput }
            let operations = try await operations(scope: scope, repository: repository)
            let raw = try await operations.pullRequest(.init(pullRequestId: id))
            try Task.checkCancellation()
            let value = raw.pullRequest
            guard value.pullRequestId == id, let targets = value.pullRequestTargets, targets.count == 1,
                  let target = targets.first, target.repositoryName == repository.name,
                  target.sourceCommit.map(Self.validSHA) ?? true, target.destinationCommit.map(Self.validSHA) ?? true,
                  target.mergeBase.map(Self.validSHA) ?? true else { throw CodeCommitBrowserError.invalidResponse }
            return .init(id: id, title: value.title, description: value.description, status: value.pullRequestStatus?.rawValue,
                         authorARN: value.authorArn, createdAt: value.creationDate, updatedAt: value.lastActivityDate,
                         sourceReference: target.sourceReference, destinationReference: target.destinationReference,
                         sourceCommit: target.sourceCommit, destinationCommit: target.destinationCommit)
        } catch { throw Self.sanitized(error) }
    }

    static func validSHA(_ value: String) -> Bool { value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil }
    static func validPath(_ value: String, rootAllowed: Bool = true) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.first == 47, bytes.count <= 4_096, !bytes.contains(0) else { return false }
        if bytes == [47] { return rootAllowed }
        guard bytes.last != 47, bytes.last != 92 else { return false }
        return bytes.dropFirst().split(separator: 47, omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.elementsEqual([46]) && !$0.elementsEqual([46, 46])
        }
    }
    static func parent(of path: String) -> String {
        let bytes = Array(path.utf8)
        guard let lastSlash = bytes.lastIndex(of: 47), lastSlash > 0 else { return "/" }
        return String(decoding: bytes[..<lastSlash], as: UTF8.self)
    }
    private static func name(of path: String) -> String {
        let bytes = Array(path.utf8)
        guard let lastSlash = bytes.lastIndex(of: 47) else { return path }
        return String(decoding: bytes[(lastSlash + 1)...], as: UTF8.self)
    }
    private static func validPullRequestID(_ value: String) -> Bool {
        value.range(of: "^[1-9][0-9]{0,99}$", options: .regularExpression) != nil
    }

    private func operations(scope: MonitoringScope, repository: CodeCommitRepository) async throws -> Operations {
        try Task.checkCancellation()
        guard scope.isValid, !scope.configPath.isEmpty, !scope.credentialsPath.isEmpty,
              UUID(uuidString: repository.id) != nil,
              repository.name.range(of: "^[A-Za-z0-9_.-]{1,100}$", options: .regularExpression) != nil else {
            throw CodeCommitBrowserError.invalidInput
        }
        let operations: Operations
        if let injected { operations = injected }
        else {
            guard let provider else { throw CodeCommitBrowserError.invalidInput }
            let client = try await provider.codeCommitClient(scope: scope)
            operations = Operations(repository: { try await client.getRepository($0) }, folder: { try await client.getFolder($0) },
                file: { try await client.getFile($0) }, differences: { try await client.getDifferences($0) },
                pullRequests: { try await client.listPullRequests($0) }, pullRequest: { try await client.getPullRequest($0) })
        }
        let raw = try await operations.repository(.init(repositoryName: repository.name)).repositoryMetadata
        try Task.checkCancellation()
        let partition = scope.principalARN.split(separator: ":", omittingEmptySubsequences: false)[1]
        guard raw?.repositoryId == repository.id, raw?.repositoryName == repository.name, raw?.accountId == scope.accountID,
              raw?.arn == "arn:\(partition):codecommit:\(scope.region):\(scope.accountID):\(repository.name)" else {
            throw CodeCommitBrowserError.invalidResponse
        }
        return operations
    }

    private static func pages<Item: Sendable>(_ load: @Sendable (String?) async throws -> ([Item], String?)) async throws -> [Item] {
        var results: [Item] = [], token: String?, tokens: Set<Data> = []
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            let (page, next) = try await load(token)
            try Task.checkCancellation()
            results.append(contentsOf: page)
            guard results.count <= 50_000 else { throw CodeCommitBrowserError.incompletePagination }
            guard let next, !next.isEmpty else { return results }
            guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, tokens.insert(Data(next.utf8)).inserted else {
                throw CodeCommitBrowserError.incompletePagination
            }
            token = next
        }
        throw CodeCommitBrowserError.incompletePagination
    }

    static func sanitized(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let known = error as? CodeCommitBrowserError { return known }
        if UserFacingError.requiresSSOLogin(error) { return CodeCommitBrowserError.credentials }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedException", "UnauthorizedOperation"].contains(code) {
            return CodeCommitBrowserError.permission
        }
        return CodeCommitBrowserError.failed
    }
}
