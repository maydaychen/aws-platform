import Foundation
import SotoCodeCommit
import SotoCore
@testable import AWSPlatform

let codeCommitRepositoryID = "00000000-1111-2222-3333-444444444444"
let codeCommitSHA = String(repeating: "a", count: 40)

struct CodeCommitFixtureError: AWSErrorType {
    let errorCode: String
    var context: AWSErrorContext? { nil }
    var description: String { "\(errorCode): private-codecommit-token" }

    init(_ code: String) { errorCode = code }
    init?(errorCode: String, context: AWSErrorContext) { self.errorCode = errorCode }
}

func codeCommitScope(account: String = "111122223333", region: String = "eu-west-1",
                     profile: String = "work", partition: String = "aws") -> MonitoringScope {
    MonitoringScope(
        profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
        identity: AWSIdentity(account: account, arn: "arn:\(partition):sts::\(account):assumed-role/Test/session", userID: "fixture"),
        region: region,
        paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/example/config", "AWS_SHARED_CREDENTIALS_FILE": "/example/credentials"])
    )
}

func codeCommitMetadata(name: String = "example", account: String = "111122223333", region: String = "eu-west-1",
                        partition: String = "aws", defaultBranch: String? = "develop") -> CodeCommit.RepositoryMetadata {
    .init(accountId: account, arn: "arn:\(partition):codecommit:\(region):\(account):\(name)",
          cloneUrlHttp: "https://git-codecommit.\(region).amazonaws.com/v1/repos/\(name)",
          cloneUrlSsh: "ssh://git-codecommit.\(region).amazonaws.com/v1/repos/\(name)",
          creationDate: Date(timeIntervalSince1970: 1_000), defaultBranch: defaultBranch,
          lastModifiedDate: Date(timeIntervalSince1970: 2_000), repositoryDescription: "Fixture repository",
          repositoryId: codeCommitRepositoryID, repositoryName: name)
}

actor CodeCommitServiceFixture {
    enum Operation: Int, CaseIterable, Sendable { case list, repository, branches, branch, commit }
    struct Requests: Sendable {
        var list: [CodeCommit.ListRepositoriesInput] = []
        var repository: [CodeCommit.GetRepositoryInput] = []
        var branches: [CodeCommit.ListBranchesInput] = []
        var branch: [CodeCommit.GetBranchInput] = []
        var commit: [CodeCommit.GetCommitInput] = []
        var total: Int { list.count + repository.count + branches.count + branch.count + commit.count }
    }

    private var calls = Requests()
    private let listPages: [CodeCommit.ListRepositoriesOutput]
    private let branchPages: [CodeCommit.ListBranchesOutput]
    private let metadata: CodeCommit.GetRepositoryOutput
    private let branchOutput: CodeCommit.GetBranchOutput
    private let commitOutput: CodeCommit.GetCommitOutput
    private let failOperation: Operation?
    private let failAt: Int
    private let failure: Error
    private let gateOperation: Operation?
    private let gate: CodeCommitRequestGate?

    init(listPages: [CodeCommit.ListRepositoriesOutput] = [.init()], branchPages: [CodeCommit.ListBranchesOutput] = [.init()],
         metadata: CodeCommit.GetRepositoryOutput = .init(repositoryMetadata: codeCommitMetadata()),
         branch: CodeCommit.GetBranchOutput = .init(branch: .init(branchName: "develop", commitId: codeCommitSHA)),
         commit: CodeCommit.GetCommitOutput = .init(commit: .init(commitId: codeCommitSHA)),
         failOperation: Operation? = nil, failAt: Int = 0,
         failure: Error = CodeCommitFixtureError("AccessDeniedException"),
         gateOperation: Operation? = nil, gate: CodeCommitRequestGate? = nil) {
        self.listPages = listPages
        self.branchPages = branchPages
        self.metadata = metadata
        branchOutput = branch
        commitOutput = commit
        self.failOperation = failOperation
        self.failAt = failAt
        self.failure = failure
        self.gateOperation = gateOperation
        self.gate = gate
    }

    func requests() -> Requests { calls }

    func list(_ input: CodeCommit.ListRepositoriesInput) async throws -> CodeCommit.ListRepositoriesOutput {
        let index = calls.list.count
        calls.list.append(input)
        try await check(.list, index: index)
        return index < listPages.count ? listPages[index] : .init()
    }

    func repository(_ input: CodeCommit.GetRepositoryInput) async throws -> CodeCommit.GetRepositoryOutput {
        let index = calls.repository.count
        calls.repository.append(input)
        try await check(.repository, index: index)
        return metadata
    }

    func branches(_ input: CodeCommit.ListBranchesInput) async throws -> CodeCommit.ListBranchesOutput {
        let index = calls.branches.count
        calls.branches.append(input)
        try await check(.branches, index: index)
        return index < branchPages.count ? branchPages[index] : .init()
    }

    func branch(_ input: CodeCommit.GetBranchInput) async throws -> CodeCommit.GetBranchOutput {
        let index = calls.branch.count
        calls.branch.append(input)
        try await check(.branch, index: index)
        return branchOutput
    }

    func commit(_ input: CodeCommit.GetCommitInput) async throws -> CodeCommit.GetCommitOutput {
        let index = calls.commit.count
        calls.commit.append(input)
        try await check(.commit, index: index)
        return commitOutput
    }

    private func check(_ operation: Operation, index: Int) async throws {
        if gateOperation == operation, let gate { await gate.enter() }
        if failOperation == operation, failAt == index { throw failure }
    }

    nonisolated var service: AWSCodeCommitService {
        AWSCodeCommitService(repositoryListLoader: { try await self.list($0) }, repositoryLoader: { try await self.repository($0) },
                             branchListLoader: { try await self.branches($0) }, branchLoader: { try await self.branch($0) },
                             commitLoader: { try await self.commit($0) })
    }
}

actor CodeCommitRequestGate {
    private var entered = false
    private var opened = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiting: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        if !opened { await withCheckedContinuation { waiting = $0 } }
    }

    func waitForEntry() async {
        if !entered { await withCheckedContinuation { enteredWaiters.append($0) } }
    }

    func open() {
        opened = true
        waiting?.resume()
        waiting = nil
    }
}
