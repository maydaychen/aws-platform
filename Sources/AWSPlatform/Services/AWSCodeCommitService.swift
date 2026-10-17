import Foundation
import SotoCodeCommit
import SotoCore

struct AWSCodeCommitService: Sendable {
    typealias RepositoryListLoader = @Sendable (CodeCommit.ListRepositoriesInput) async throws -> CodeCommit.ListRepositoriesOutput
    typealias RepositoryLoader = @Sendable (CodeCommit.GetRepositoryInput) async throws -> CodeCommit.GetRepositoryOutput
    typealias BranchListLoader = @Sendable (CodeCommit.ListBranchesInput) async throws -> CodeCommit.ListBranchesOutput
    typealias BranchLoader = @Sendable (CodeCommit.GetBranchInput) async throws -> CodeCommit.GetBranchOutput
    typealias CommitLoader = @Sendable (CodeCommit.GetCommitInput) async throws -> CodeCommit.GetCommitOutput

    private struct Operations: Sendable {
        let repositories: RepositoryListLoader
        let repository: RepositoryLoader
        let branches: BranchListLoader
        let branch: BranchLoader
        let commit: CommitLoader
    }

    private let provider: AWSServiceProvider?
    private let injected: Operations?

    init(provider: AWSServiceProvider) {
        self.provider = provider
        injected = nil
    }

    init(repositoryListLoader: @escaping RepositoryListLoader, repositoryLoader: @escaping RepositoryLoader,
         branchListLoader: @escaping BranchListLoader, branchLoader: @escaping BranchLoader,
         commitLoader: @escaping CommitLoader) {
        provider = nil
        injected = Operations(repositories: repositoryListLoader, repository: repositoryLoader,
                              branches: branchListLoader, branch: branchLoader, commit: commitLoader)
    }

    func loadRepositories(scope: MonitoringScope) async throws -> [CodeCommitRepository] {
        do {
            let operations = try await operations(scope: scope)
            let values: [CodeCommitRepository] = try await Self.pages { token in
                let response = try await operations.repositories(.init(nextToken: token, order: .ascending, sortBy: .repositoryName))
                try Task.checkCancellation()
                return (try (response.repositories ?? []).map { raw in
                    guard let id = raw.repositoryId, Self.isRepositoryID(id), let name = raw.repositoryName,
                          Self.isRepositoryName(name) else { throw CodeCommitError.invalidResponse }
                    return CodeCommitRepository(id: id, name: name)
                }, response.nextToken)
            }
            guard Set(values.map(\.id)).count == values.count,
                  Set(values.map(\.name)).count == values.count else { throw CodeCommitError.invalidResponse }
            return values.sorted { $0.name < $1.name }
        } catch { throw Self.sanitized(error, operation: .repositories) }
    }

    func loadRepository(scope: MonitoringScope, repositoryName: String) async throws -> CodeCommitRepositoryDetail {
        do {
            try Self.validate(scope: scope, repositoryName: repositoryName)
            let operations = try await operations(scope: scope)
            try Task.checkCancellation()
            let response = try await operations.repository(.init(repositoryName: repositoryName))
            try Task.checkCancellation()
            guard let raw = response.repositoryMetadata, let id = raw.repositoryId, Self.isRepositoryID(id),
                  raw.repositoryName == repositoryName, raw.accountId == scope.accountID,
                  let arn = raw.arn, Self.matchesRepositoryARN(arn, name: repositoryName, scope: scope),
                  raw.defaultBranch.map(Self.isBranchName) ?? true else { throw CodeCommitError.invalidResponse }
            return CodeCommitRepositoryDetail(
                id: id, name: repositoryName, arn: arn, accountID: scope.accountID,
                description: raw.repositoryDescription, defaultBranch: raw.defaultBranch,
                cloneURLHTTP: raw.cloneUrlHttp, cloneURLSSH: raw.cloneUrlSsh,
                creationDate: raw.creationDate, lastModifiedDate: raw.lastModifiedDate
            )
        } catch { throw Self.sanitized(error, operation: .repository) }
    }

    func loadBranches(scope: MonitoringScope, repositoryName: String) async throws -> [String] {
        do {
            try Self.validate(scope: scope, repositoryName: repositoryName)
            let operations = try await operations(scope: scope)
            let branches: [String] = try await Self.pages { token in
                let response = try await operations.branches(.init(nextToken: token, repositoryName: repositoryName))
                try Task.checkCancellation()
                let branches = response.branches ?? []
                guard branches.allSatisfy(Self.isBranchName) else { throw CodeCommitError.invalidResponse }
                return (branches, response.nextToken)
            }
            guard Set(branches).count == branches.count else { throw CodeCommitError.invalidResponse }
            return branches.sorted()
        } catch { throw Self.sanitized(error, operation: .branches) }
    }

    func loadCommit(scope: MonitoringScope, repositoryName: String, branchName: String) async throws -> CodeCommitCommit {
        let operations: Operations
        let sha: String
        do {
            try Self.validate(scope: scope, repositoryName: repositoryName)
            guard Self.isBranchName(branchName) else { throw CodeCommitError.invalidInput }
            operations = try await self.operations(scope: scope)
            try Task.checkCancellation()
            let response = try await operations.branch(.init(branchName: branchName, repositoryName: repositoryName))
            try Task.checkCancellation()
            guard let branch = response.branch, branch.branchName == branchName,
                  let id = branch.commitId, Self.isCommitID(id) else { throw CodeCommitError.invalidResponse }
            sha = id
        } catch { throw Self.sanitized(error, operation: .branch) }
        do {
            try Task.checkCancellation()
            let response = try await operations.commit(.init(commitId: sha, repositoryName: repositoryName))
            try Task.checkCancellation()
            let raw = response.commit
            guard raw.commitId == sha, (raw.parents ?? []).allSatisfy(Self.isCommitID) else {
                throw CodeCommitError.invalidResponse
            }
            return CodeCommitCommit(
                id: sha, message: raw.message, authorName: raw.author?.name, authorEmail: raw.author?.email,
                authorDate: raw.author?.date, committerName: raw.committer?.name, committerEmail: raw.committer?.email,
                committerDate: raw.committer?.date, parentIDs: raw.parents ?? []
            )
        } catch { throw Self.sanitized(error, operation: .commit) }
    }

    private func operations(scope: MonitoringScope) async throws -> Operations {
        try Self.validate(scope: scope)
        if let injected { return injected }
        guard let provider else { throw CodeCommitError.invalidScope }
        let client = try await provider.codeCommitClient(scope: scope)
        try Task.checkCancellation()
        return Operations(repositories: { try await client.listRepositories($0) },
                          repository: { try await client.getRepository($0) }, branches: { try await client.listBranches($0) },
                          branch: { try await client.getBranch($0) }, commit: { try await client.getCommit($0) })
    }

    private static func validate(scope: MonitoringScope, repositoryName: String? = nil) throws {
        try Task.checkCancellation()
        guard scope.isValid, !scope.configPath.isEmpty, !scope.credentialsPath.isEmpty else { throw CodeCommitError.invalidScope }
        if let repositoryName, !isRepositoryName(repositoryName) { throw CodeCommitError.invalidInput }
    }

    private static func pages<Item: Sendable>(
        _ loader: @Sendable (String?) async throws -> ([Item], String?)
    ) async throws -> [Item] {
        var items: [Item] = []
        var token: String?
        var seenTokens: Set<String> = []
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            let (page, next) = try await loader(token)
            try Task.checkCancellation()
            items.append(contentsOf: page)
            guard let next, !next.isEmpty else { return items }
            guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seenTokens.insert(next).inserted else { throw CodeCommitError.incompletePagination }
            token = next
        }
        throw CodeCommitError.incompletePagination
    }

    private static func isRepositoryID(_ value: String) -> Bool {
        value.range(of: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
                    options: .regularExpression) != nil
    }

    private static func isRepositoryName(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_.-]{1,100}$", options: .regularExpression) != nil
    }

    private static func isBranchName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 256, value != "@", value != "HEAD",
              !value.hasPrefix("/"), !value.hasSuffix("/"), !value.hasPrefix("-"), !value.hasSuffix("."),
              !value.contains(".."), !value.contains("//"), !value.contains("@{"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
              !value.contains(where: { "~^:?*[\\".contains($0) }) else { return false }
        return value.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }

    private static func isCommitID(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    }

    private static func matchesRepositoryARN(_ value: String, name: String, scope: MonitoringScope) -> Bool {
        let partition = scope.principalARN.split(separator: ":", omittingEmptySubsequences: false)[1]
        return value == "arn:\(partition):codecommit:\(scope.region):\(scope.accountID):\(name)"
    }

    private enum Operation { case repositories, repository, branches, branch, commit }

    private static func sanitized(_ error: Error, operation: Operation) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? CodeCommitError { return error }
        if let error = error as? RequestError { return error }
        if error is AWSServiceError { return CodeCommitError.invalidScope }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedException", "UnauthorizedOperation", "ForbiddenException"].contains(code) {
            switch operation {
            case .repositories: return RequestError.repositoriesPermission
            case .repository: return RequestError.repositoryPermission
            case .branches: return RequestError.branchesPermission
            case .branch: return RequestError.branchPermission
            case .commit: return RequestError.commitPermission
            }
        }
        if UserFacingError.requiresSSOLogin(error) { return RequestError.credentials }
        if error is URLError { return RequestError.network }
        switch code {
        case "Throttling", "ThrottlingException", "TooManyRequestsException": return RequestError.throttled
        case "RepositoryDoesNotExistException", "BranchDoesNotExistException", "CommitDoesNotExistException",
             "CommitIdDoesNotExistException", "InvalidCommitIdException": return RequestError.notFound
        case "EmptyRepositoryException": return RequestError.emptyRepository
        case "EncryptionKeyAccessDeniedException", "EncryptionKeyDisabledException", "EncryptionKeyNotFoundException",
             "EncryptionIntegrityChecksFailedException", "EncryptionKeyUnavailableException", "EncryptionKeyInvalidIdException",
             "EncryptionKeyInvalidUsageException": return RequestError.encryption
        case "InvalidContinuationTokenException", "InvalidNextToken", "InvalidNextTokenException": return CodeCommitError.incompletePagination
        default: return RequestError.failed
        }
    }

    enum RequestError: LocalizedError, Equatable {
        case repositoriesPermission, repositoryPermission, branchesPermission, branchPermission, commitPermission
        case credentials, network, throttled, notFound, emptyRepository, encryption, failed

        var errorDescription: String? {
            switch self {
            case .repositoriesPermission: return "Repository access was denied. Check codecommit:ListRepositories permission for the selected profile."
            case .repositoryPermission: return "Repository details could not be read. Check codecommit:GetRepository permission for this repository."
            case .branchesPermission: return "Branches could not be read. Check codecommit:ListBranches permission for this repository."
            case .branchPermission: return "The branch could not be read. Check codecommit:GetBranch permission for this repository."
            case .commitPermission: return "The commit could not be read. Check codecommit:GetCommit permission for this repository."
            case .credentials: return "AWS credentials expired or are unavailable. Sign in to the session, select the profile again, then reload CodeCommit."
            case .network: return "Unable to reach CodeCommit. Check your network or proxy, then refresh."
            case .throttled: return "CodeCommit is limiting requests. Wait a moment, then refresh manually."
            case .notFound: return "The CodeCommit repository, branch or commit is no longer available. Refresh the repository list."
            case .emptyRepository: return "This CodeCommit repository has no commits yet."
            case .encryption: return "CodeCommit could not decrypt this repository. Check its KMS key status and permissions."
            case .failed: return "The CodeCommit request failed. Check the selected profile, region and service availability, then refresh."
            }
        }
    }
}
