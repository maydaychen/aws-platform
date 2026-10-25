import XCTest
@testable import AWSPlatform

@MainActor
final class CodeCommitViewModelTests: XCTestCase {
    func testMissingInvalidScopeAndConfigureAloneNeverQuery() async {
        let probe = CodeCommitStateProbe()
        let vm = makeVM(probe)
        for scope in [nil, ccStateScope(account: ""), ccStateScope(region: "invalid")] {
            vm.configure(scope: scope)
            vm.loadIfNeeded()
            vm.refresh()
            vm.refreshRepository()
            vm.refreshCommit()
            await vm.waitForLoading()
        }
        vm.configure(scope: ccStateScope())
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0, 0, 0])
        XCTAssertNil(vm.selectedRepository)
    }

    func testListDeduplicatesLoadsSearchesLocallyAndNeverAutoSelects() async {
        let gate = TestGate()
        let probe = CodeCommitStateProbe(gates: ["list-1": gate])
        let vm = makeVM(probe)
        vm.configure(scope: ccStateScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        vm.loadIfNeeded()
        await gate.open()
        await vm.waitForLoading()
        vm.loadIfNeeded()
        XCTAssertNil(vm.selectedRepository)
        vm.searchText = " ONE "
        XCTAssertEqual(vm.filteredRepositories, [ccStateRepository("one")])
        vm.searchText = "id-two"
        XCTAssertEqual(vm.filteredRepositories, [ccStateRepository("two")])
        vm.searchText = "missing"
        XCTAssertTrue(vm.filteredRepositories.isEmpty)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
    }

    func testSelectionLoadsMetadataAndBranchesThenVerifiedDefaultCommit() async {
        let probe = CodeCommitStateProbe(defaultBranch: "trunk", branchRows: ["dev", "trunk"])
        let vm = makeVM(probe)
        await loadList(vm)
        vm.selectedRepository = vm.repositories[0]
        await vm.waitForDetails()
        XCTAssertEqual(vm.repositoryDetail?.name, "one")
        XCTAssertEqual(vm.branches, ["dev", "trunk"])
        XCTAssertEqual(vm.selectedBranch, "trunk")
        XCTAssertEqual(vm.commit?.message, "one/trunk")
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1, 1])
        vm.selectedRepository = vm.repositories[0]
        vm.selectedBranch = "trunk"
        await vm.waitForDetails()
        let unchanged = await probe.counts()
        XCTAssertEqual(unchanged, counts)
    }

    func testEmptyRepositoryAndMissingDefaultDoNotRequestCommit() async {
        for (branches, defaultBranch) in [([], "main"), (["dev"], "main"), (["dev"], nil)] as [([String], String?)] {
            let probe = CodeCommitStateProbe(defaultBranch: defaultBranch, branchRows: branches)
            let vm = makeVM(probe)
            await loadList(vm)
            vm.selectedRepository = vm.repositories[0]
            await vm.waitForDetails()
            XCTAssertNil(vm.selectedBranch)
            XCTAssertNil(vm.commit)
            XCTAssertNil(vm.branchesError)
            let counts = await probe.counts()
            XCTAssertEqual(counts, [1, 1, 1, 0])
        }
    }

    func testLateMetadataCannotOverrideManualBranch() async {
        let gate = TestGate()
        let probe = CodeCommitStateProbe(gates: ["repository-1": gate])
        let vm = makeVM(probe)
        await loadList(vm)
        vm.selectedRepository = vm.repositories[0]
        await gate.waitForEntry()
        await eventually { vm.branches.count == 2 }
        vm.selectedBranch = "dev"
        await eventually { vm.commit?.message == "one/dev" }
        await gate.open()
        await vm.waitForDetails()
        XCTAssertEqual(vm.selectedBranch, "dev")
        XCTAssertEqual(vm.commit?.message, "one/dev")
    }

    func testLateBranchesCannotSelectUnverifiedDefault() async {
        let gate = TestGate()
        let probe = CodeCommitStateProbe(gates: ["branches-1": gate])
        let vm = makeVM(probe)
        await loadList(vm)
        vm.selectedRepository = vm.repositories[0]
        await gate.waitForEntry()
        await eventually { vm.repositoryDetail != nil }
        XCTAssertNil(vm.selectedBranch)
        XCTAssertNil(vm.commit)
        await gate.open()
        await vm.waitForDetails()
        XCTAssertEqual(vm.selectedBranch, "main")
    }

    func testMetadataAndBranchesFailuresAreIndependentAndRetryRecovers() async {
        for operation in ["repository", "branches"] {
            let probe = CodeCommitStateProbe(failures: ["\(operation)-1"])
            let vm = makeVM(probe)
            await loadList(vm)
            vm.selectedRepository = vm.repositories[0]
            await vm.waitForDetails()
            XCTAssertEqual(vm.repositories.count, 2)
            if operation == "repository" {
                XCTAssertNil(vm.repositoryDetail)
                XCTAssertNotNil(vm.repositoryError)
                XCTAssertEqual(vm.branches.count, 2)
                vm.selectedBranch = "dev"
                await vm.waitForDetails()
                XCTAssertEqual(vm.commit?.message, "one/dev")
            } else {
                XCTAssertNotNil(vm.repositoryDetail)
                XCTAssertNotNil(vm.branchesError)
                XCTAssertTrue(vm.branches.isEmpty)
            }
            vm.refreshRepository()
            await vm.waitForDetails()
            XCTAssertNotNil(vm.repositoryDetail)
            XCTAssertEqual(vm.branches.count, 2)
            XCTAssertNil(vm.repositoryError)
            XCTAssertNil(vm.branchesError)
        }
    }

    func testListAndCommitFailuresDoNotLeakRawErrorsAndCanRetry() async {
        let probe = CodeCommitStateProbe(failures: ["list-1", "commit-1"])
        let vm = makeVM(probe)
        await loadList(vm)
        XCTAssertNotNil(vm.error)
        XCTAssertFalse(vm.error?.contains("secret") == true)
        vm.refresh()
        await vm.waitForLoading()
        vm.selectedRepository = vm.repositories[0]
        await vm.waitForDetails()
        XCTAssertNotNil(vm.commitError)
        XCTAssertNotNil(vm.repositoryDetail)
        XCTAssertEqual(vm.selectedBranch, "main")
        XCTAssertFalse(vm.commitError?.contains("secret") == true)
        vm.refreshCommit()
        await vm.waitForDetails()
        XCTAssertNotNil(vm.commit)
        XCTAssertNil(vm.commitError)
    }

    func testUnlistedOrModifiedRepositoryAndBranchCannotQuery() async {
        let probe = CodeCommitStateProbe()
        let vm = makeVM(probe)
        await loadList(vm)
        vm.selectedRepository = ccStateRepository("foreign")
        vm.selectedBranch = "main"
        vm.refreshCommit()
        await vm.waitForDetails()
        XCTAssertNil(vm.selectedRepository)
        XCTAssertNil(vm.selectedBranch)
        var counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
        vm.selectedRepository = vm.repositories[0]
        await vm.waitForDetails()
        vm.selectedBranch = "foreign"
        await vm.waitForDetails()
        XCTAssertNil(vm.selectedBranch)
        XCTAssertNil(vm.commit)
        counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1, 1, 1])
    }

    func testRefreshPreservesRepositoryAndManuallySelectedBranch() async {
        let probe = CodeCommitStateProbe()
        let vm = makeVM(probe)
        await loadList(vm)
        vm.selectedRepository = vm.repositories[0]
        await vm.waitForDetails()
        vm.selectedBranch = "dev"
        await vm.waitForDetails()
        vm.refresh()
        XCTAssertNil(vm.repositoryDetail)
        XCTAssertNil(vm.commit)
        await vm.waitForLoading()
        await vm.waitForDetails()
        XCTAssertEqual(vm.selectedRepository?.name, "one")
        XCTAssertEqual(vm.selectedBranch, "dev")
        XCTAssertEqual(vm.commit?.message, "one/dev")
    }

    func testProfileRegionIdentityAndPathsChangeClearAllState() async {
        let probe = CodeCommitStateProbe()
        let vm = makeVM(probe)
        let scopes = [ccStateScope(), ccStateScope(profile: "other"), ccStateScope(region: "eu-west-1"),
                      ccStateScope(account: "444455556666"), ccStateScope(role: "Other"),
                      ccStateScope(paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/cc-other"]))]
        for scope in scopes {
            vm.configure(scope: scope)
            XCTAssertTrue(vm.repositories.isEmpty)
            XCTAssertNil(vm.selectedRepository)
            XCTAssertNil(vm.repositoryDetail)
            XCTAssertTrue(vm.branches.isEmpty)
            XCTAssertNil(vm.selectedBranch)
            XCTAssertNil(vm.commit)
            XCTAssertEqual(vm.searchText, "")
            vm.refresh()
            await vm.waitForLoading()
            vm.selectedRepository = vm.repositories[0]
            await vm.waitForDetails()
            vm.searchText = "test"
        }
        vm.reset()
        XCTAssertNil(vm.scope)
        XCTAssertNil(vm.commit)
    }

    func testSameScopeConfigureDoesNotRestartInFlightQuery() async {
        let gate = TestGate()
        let probe = CodeCommitStateProbe(gates: ["list-1": gate])
        let vm = makeVM(probe)
        let scope = ccStateScope()
        vm.configure(scope: scope)
        vm.refresh()
        await gate.waitForEntry()
        vm.configure(scope: scope)
        XCTAssertTrue(vm.isLoading)
        await gate.open()
        await vm.waitForLoading()
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
    }

    func testEmptyListIsSuccessfulAndOnlyExplicitRefreshRetries() async {
        let probe = CodeCommitStateProbe(repositoryRows: [])
        let vm = makeVM(probe)
        await loadList(vm)
        vm.loadIfNeeded()
        XCTAssertTrue(vm.repositories.isEmpty)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.selectedRepository)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 0, 0, 0])
    }

    func testRepositorySwitchDoesNotReusePreviousRepositoryBranchChoice() async {
        let probe = CodeCommitStateProbe()
        let vm = makeVM(probe)
        await loadList(vm)
        vm.selectedRepository = vm.repositories[0]
        await vm.waitForDetails()
        vm.selectedBranch = "dev"
        await vm.waitForDetails()
        vm.selectedRepository = vm.repositories[1]
        XCTAssertNil(vm.commit)
        await vm.waitForDetails()
        XCTAssertEqual(vm.selectedBranch, "main")
        XCTAssertEqual(vm.commit?.message, "two/main")
    }

    func testRetryAfterListRefreshFailureRestoresSameRepositoryAndBranch() async {
        let probe = CodeCommitStateProbe(failures: ["list-2"])
        let vm = makeVM(probe)
        await loadList(vm)
        vm.selectedRepository = vm.repositories[0]
        await vm.waitForDetails()
        vm.selectedBranch = "dev"
        await vm.waitForDetails()
        vm.refresh()
        await vm.waitForLoading()
        XCTAssertNotNil(vm.error)
        XCTAssertNil(vm.repositoryDetail)
        vm.refresh()
        await vm.waitForLoading()
        await vm.waitForDetails()
        XCTAssertEqual(vm.selectedRepository?.name, "one")
        XCTAssertEqual(vm.selectedBranch, "dev")
        XCTAssertNil(vm.error)
    }

    func testLateListCannotOverwriteNewScopeOrNewRefresh() async {
        for changeScope in [false, true] {
            let gate = TestGate()
            let probe = CodeCommitStateProbe(gates: ["list-1": gate])
            let vm = makeVM(probe)
            vm.configure(scope: ccStateScope())
            vm.refresh()
            await gate.waitForEntry()
            if changeScope { vm.configure(scope: ccStateScope(profile: "other")) }
            vm.refresh()
            await vm.waitForLoading()
            vm.selectedRepository = vm.repositories[0]
            await vm.waitForDetails()
            await gate.open()
            await eventually { await probe.finished("list-1") }
            for _ in 0..<10 { await Task.yield() }
            XCTAssertNotNil(vm.selectedRepository)
            XCTAssertNotNil(vm.repositoryDetail)
            XCTAssertNil(vm.error)
        }
    }

    func testLateDetailsCannotOverwriteRepositoryScopeOrSameRepositoryRefresh() async {
        for scenario in ["repository-repository", "branches-repository", "repository-scope", "branches-scope",
                         "repository-refresh", "branches-refresh"] {
            let parts = scenario.split(separator: "-").map(String.init)
            let operation = parts[0]
            let transition = parts[1]
            let gate = TestGate()
            let probe = CodeCommitStateProbe(gates: ["\(operation)-1": gate])
            let vm = makeVM(probe)
            await loadList(vm)
            vm.selectedRepository = vm.repositories[0]
            await gate.waitForEntry()
            if transition == "scope" {
                vm.configure(scope: ccStateScope(profile: "other"))
                vm.refresh()
                await vm.waitForLoading()
                vm.selectedRepository = vm.repositories[0]
            } else if transition == "repository" {
                vm.selectedRepository = vm.repositories[1]
            } else {
                vm.refreshRepository()
            }
            await vm.waitForDetails()
            let expected = vm.repositoryDetail
            await gate.open()
            await eventually { await probe.finished("\(operation)-1") }
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(vm.repositoryDetail, expected)
            XCTAssertEqual(vm.commit?.message, "\(vm.selectedRepository!.name)/main")
        }
    }

    func testLateCommitCannotOverwriteBranchRefreshOrScope() async {
        for transition in ["branch", "refresh", "scope"] {
            let gate = TestGate()
            let probe = CodeCommitStateProbe(gates: ["commit-1": gate])
            let vm = makeVM(probe)
            await loadList(vm)
            vm.selectedRepository = vm.repositories[0]
            await gate.waitForEntry()
            if transition == "scope" {
                vm.configure(scope: ccStateScope(profile: "other"))
                vm.refresh()
                await vm.waitForLoading()
                vm.selectedRepository = vm.repositories[0]
            } else if transition == "branch" {
                vm.selectedBranch = "dev"
            } else {
                vm.refreshCommit()
            }
            await vm.waitForDetails()
            let expected = vm.commit
            await gate.open()
            await eventually { await probe.finished("commit-1") }
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(vm.commit, expected)
            XCTAssertFalse(vm.isCommitLoading)
        }
    }

    func testCancellationInvalidatesLateListAndEveryDetailCallback() async {
        for operation in ["list", "repository", "branches", "commit"] {
            let gate = TestGate()
            let probe = CodeCommitStateProbe(gates: ["\(operation)-1": gate])
            let vm = makeVM(probe)
            vm.configure(scope: ccStateScope())
            vm.refresh()
            if operation != "list" {
                await vm.waitForLoading()
                vm.selectedRepository = vm.repositories[0]
            }
            await gate.waitForEntry()
            vm.cancelLoading()
            XCTAssertFalse(vm.isLoading || vm.isRepositoryLoading || vm.isBranchesLoading || vm.isCommitLoading)
            XCTAssertNil(vm.repositoryDetail)
            XCTAssertTrue(vm.branches.isEmpty)
            XCTAssertNil(vm.commit)
            await gate.open()
            await eventually { await probe.finished("\(operation)-1") }
            for _ in 0..<10 { await Task.yield() }
            XCTAssertNil(vm.repositoryDetail)
            XCTAssertTrue(vm.branches.isEmpty)
            XCTAssertNil(vm.commit)
        }
    }

    func testCancellingOnlyCommitShowsCancellationInsteadOfEmptyRepository() async {
        let gate = TestGate()
        let probe = CodeCommitStateProbe(gates: ["commit-1": gate])
        let vm = makeVM(probe)
        await loadList(vm)
        vm.selectedRepository = vm.repositories[0]
        await gate.waitForEntry()
        XCTAssertNotNil(vm.repositoryDetail)
        XCTAssertFalse(vm.branches.isEmpty)
        XCTAssertFalse(vm.isRepositoryLoading || vm.isBranchesLoading)
        XCTAssertTrue(vm.isCommitLoading)

        vm.cancelLoading()

        let message = "Loading cancelled. Use Refresh to try again."
        XCTAssertEqual(vm.repositoryError, message)
        XCTAssertEqual(vm.branchesError, message)
        XCTAssertEqual(vm.commitError, message)
        XCTAssertNil(vm.repositoryDetail)
        XCTAssertTrue(vm.branches.isEmpty)
        XCTAssertNil(vm.selectedBranch)
        await gate.open()
        await eventually { await probe.finished("commit-1") }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(vm.branchesError, message)
        XCTAssertNil(vm.commit)
    }

    private func makeVM(_ probe: CodeCommitStateProbe) -> CodeCommitViewModel {
        CodeCommitViewModel(listLoader: { try await probe.list($0) },
                            repositoryLoader: { try await probe.repository($0, $1) },
                            branchesLoader: { try await probe.branches($0, $1) },
                            commitLoader: { try await probe.commit($0, $1, $2) })
    }

    private func loadList(_ vm: CodeCommitViewModel) async {
        vm.configure(scope: ccStateScope())
        vm.refresh()
        await vm.waitForLoading()
    }

    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("State transition did not complete", file: file, line: line)
    }
}

private actor CodeCommitStateProbe {
    private var calls: [String: Int] = [:]
    private var completed: Set<String> = []
    private let gates: [String: TestGate]
    private let failures: Set<String>
    private let defaultBranch: String?
    private let branchRows: [String]
    private let repositoryRows: [CodeCommitRepository]

    init(gates: [String: TestGate] = [:], failures: Set<String> = [], defaultBranch: String? = "main",
         branchRows: [String] = ["dev", "main"], repositoryRows: [CodeCommitRepository] = [ccStateRepository("one"), ccStateRepository("two")]) {
        self.gates = gates
        self.failures = failures
        self.defaultBranch = defaultBranch
        self.branchRows = branchRows
        self.repositoryRows = repositoryRows
    }

    func counts() -> [Int] { ["list", "repository", "branches", "commit"].map { calls[$0, default: 0] } }
    func finished(_ key: String) -> Bool { completed.contains(key) }
    private func request(_ operation: String) async throws {
        calls[operation, default: 0] += 1
        let key = "\(operation)-\(calls[operation]!)"
        await gates[key]?.wait()
        completed.insert(key)
        if failures.contains(key) { throw NSError(domain: "secret-response", code: 1) }
    }

    func list(_ scope: MonitoringScope) async throws -> [CodeCommitRepository] {
        try await request("list")
        return repositoryRows
    }
    func repository(_ scope: MonitoringScope, _ name: String) async throws -> CodeCommitRepositoryDetail {
        try await request("repository")
        return .init(id: "id-\(name)", name: name, arn: "arn:aws:codecommit:\(scope.region):\(scope.accountID):\(name)",
                     accountID: scope.accountID, description: nil, defaultBranch: defaultBranch,
                     cloneURLHTTP: nil, cloneURLSSH: nil, creationDate: nil, lastModifiedDate: nil)
    }
    func branches(_ scope: MonitoringScope, _ name: String) async throws -> [String] {
        try await request("branches")
        return branchRows
    }
    func commit(_ scope: MonitoringScope, _ name: String, _ branch: String) async throws -> CodeCommitCommit {
        try await request("commit")
        return .init(id: String(repeating: "a", count: 40), message: "\(name)/\(branch)", authorName: nil, authorEmail: nil,
                     authorDate: nil, committerName: nil, committerEmail: nil, committerDate: nil, parentIDs: [])
    }
}

private func ccStateRepository(_ name: String) -> CodeCommitRepository { .init(id: "id-\(name)", name: name) }
private func ccStateScope(profile: String = "test", account: String = "111122223333", region: String = "us-east-1",
                          role: String = "ReadOnly", paths: AWSConfigurationPaths = AWSConfigurationPaths()) -> MonitoringScope {
    MonitoringScope(profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil,
                                        ssoAccountID: nil, ssoRoleName: nil),
                    identity: AWSIdentity(account: account, arn: "arn:aws:sts::\(account):assumed-role/\(role)/test", userID: "fixture"),
                    region: region, paths: paths)
}
