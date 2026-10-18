import XCTest
@testable import AWSPlatform

@MainActor
final class RDSViewModelTests: XCTestCase {
    func testMissingInvalidScopeAndConfigureAloneNeverQuery() async {
        let probe = RDSStateProbe()
        let vm = makeVM(probe)
        for scope in [nil, rdsStateScope(profile: ""), rdsStateScope(account: ""), rdsStateScope(region: "invalid")] {
            vm.configure(scope: scope)
            vm.loadIfNeeded()
            vm.refresh()
            await vm.waitForLoading()
            XCTAssertFalse(vm.isLoading)
            XCTAssertTrue(vm.databases.isEmpty)
        }
        vm.configure(scope: rdsStateScope())
        XCTAssertNil(vm.selectedDatabase)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [0, 0])
    }

    func testIndependentResultsAppearBeforeOtherTypeFinishesWithoutAutoSelection() async {
        let gate = TestGate()
        let probe = RDSStateProbe(gates: ["cluster-1": gate])
        let vm = makeVM(probe)
        vm.configure(scope: rdsStateScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        await eventually { !vm.isInstancesLoading }
        XCTAssertEqual(vm.instances.count, 2)
        XCTAssertTrue(vm.clusters.isEmpty)
        XCTAssertTrue(vm.isClustersLoading)
        XCTAssertTrue(vm.isLoading)
        XCTAssertNil(vm.selectedDatabase)
        vm.loadIfNeeded()
        await gate.open()
        await vm.waitForLoading()
        vm.loadIfNeeded()
        XCTAssertEqual(vm.databases.count, 4)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.selectedDatabase)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1])
    }

    func testEachTypeFailurePreservesOtherTypeAndExplicitRefreshRecovers() async {
        for failedKind in RDSResourceKind.allCases {
            let probe = RDSStateProbe(failures: ["\(failedKind.rawValue)-1"])
            let vm = makeVM(probe)
            await load(vm)
            XCTAssertEqual(vm.instances.count, failedKind == .instance ? 0 : 2)
            XCTAssertEqual(vm.clusters.count, failedKind == .cluster ? 0 : 2)
            XCTAssertEqual(vm.instanceError != nil, failedKind == .instance)
            XCTAssertEqual(vm.clusterError != nil, failedKind == .cluster)
            XCTAssertFalse(vm.error?.contains("secret") == true)
            vm.selectedDatabase = vm.databases[0]
            XCTAssertNotNil(vm.selectedDatabase)
            vm.loadIfNeeded()
            var counts = await probe.counts()
            XCTAssertEqual(counts, [1, 1])
            vm.refresh()
            await vm.waitForLoading()
            XCTAssertEqual(vm.databases.count, 4)
            XCTAssertNil(vm.error)
            counts = await probe.counts()
            XCTAssertEqual(counts, [2, 2])
        }
    }

    func testDualFailureSummarizesSafeOperationErrorsAndDoesNotAppearSuccessfulEmpty() async {
        let probe = RDSStateProbe(failures: ["instance-1", "cluster-1"])
        let vm = makeVM(probe)
        await load(vm)
        XCTAssertTrue(vm.databases.isEmpty)
        XCTAssertEqual(vm.instanceError, "Unable to load RDS DB instances. Refresh to try again.")
        XCTAssertEqual(vm.clusterError, "Unable to load RDS DB clusters. Refresh to try again.")
        XCTAssertEqual(vm.error, [vm.instanceError!, vm.clusterError!].joined(separator: "\n"))
        XCTAssertFalse(vm.error?.contains("secret") == true)
        XCTAssertFalse(vm.isLoading)
    }

    func testSafeDomainErrorAndCancellationAreKeptWithoutRawFailureText() async {
        let probe = RDSStateProbe(safeFailures: ["instance-1"], cancellations: ["cluster-1"])
        let vm = makeVM(probe)
        await load(vm)
        XCTAssertEqual(vm.instanceError, RDSError.invalidResponse.localizedDescription)
        XCTAssertEqual(vm.clusterError, "Loading cancelled. Use Refresh to try again.")
    }

    func testPermissionErrorsPreserveTheirSafeOperationSpecificMessages() async {
        let vm = RDSViewModel(instanceLoader: { _ in throw AWSRDSService.RequestError.instancesPermission },
                              clusterLoader: { _ in throw AWSRDSService.RequestError.clustersPermission })
        await load(vm)
        XCTAssertEqual(vm.instanceError, AWSRDSService.RequestError.instancesPermission.localizedDescription)
        XCTAssertEqual(vm.clusterError, AWSRDSService.RequestError.clustersPermission.localizedDescription)
        XCTAssertTrue(vm.databases.isEmpty)
    }

    func testSuccessfulEmptyListsDoNotRetryUntilExplicitRefresh() async {
        let probe = RDSStateProbe(rows: ["instance-1": [], "cluster-1": []])
        let vm = makeVM(probe)
        await load(vm)
        vm.loadIfNeeded()
        XCTAssertTrue(vm.databases.isEmpty)
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.selectedDatabase)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1])
    }

    func testLocalSearchAndKindFilterNeverRequestMoreData() async {
        let probe = RDSStateProbe()
        let vm = makeVM(probe)
        await load(vm)
        vm.searchText = " SHARED "
        XCTAssertEqual(vm.filteredDatabases.count, 2)
        vm.kindFilter = .cluster
        XCTAssertEqual(vm.filteredDatabases, [rdsStateDatabase(kind: .cluster)])
        vm.kindFilter = nil
        vm.searchText = "AURORA"
        XCTAssertEqual(vm.filteredDatabases.count, 2)
        vm.searchText = "db:shared"
        XCTAssertEqual(vm.filteredDatabases, [rdsStateDatabase()])
        vm.searchText = "shared.db.example"
        XCTAssertEqual(vm.filteredDatabases, [rdsStateDatabase()])
        vm.searchText = "reader.example"
        XCTAssertEqual(vm.filteredDatabases.count, 2)
        vm.kindFilter = .instance
        XCTAssertTrue(vm.filteredDatabases.isEmpty)
        vm.searchText = "missing"
        XCTAssertTrue(vm.filteredDatabases.isEmpty)
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1])
    }

    func testSameIdentifierTypesRemainDistinctAndOnlyLoadedRowsCanBeSelected() async {
        let vm = makeVM(RDSStateProbe())
        await load(vm)
        let instance = rdsStateDatabase()
        let cluster = rdsStateDatabase(kind: .cluster)
        XCTAssertEqual(instance.identifier, cluster.identifier)
        XCTAssertNotEqual(instance.id, cluster.id)
        vm.selectedDatabase = instance
        XCTAssertEqual(vm.selectedDatabase, instance)
        vm.selectedDatabase = cluster
        XCTAssertEqual(vm.selectedDatabase, cluster)
        vm.selectedDatabase = rdsStateDatabase(status: "modified")
        XCTAssertNil(vm.selectedDatabase)
        vm.selectedDatabase = rdsStateDatabase("unlisted")
        XCTAssertNil(vm.selectedDatabase)
    }

    func testRefreshRestoresExactlyTheSameARNWithUpdatedMetadata() async {
        let updated = rdsStateDatabase(kind: .cluster, status: "modifying")
        let probe = RDSStateProbe(rows: ["cluster-2": [updated]])
        let vm = makeVM(probe)
        await load(vm)
        vm.selectedDatabase = rdsStateDatabase(kind: .cluster)
        vm.refresh()
        XCTAssertTrue(vm.databases.isEmpty)
        XCTAssertNil(vm.selectedDatabase)
        await vm.waitForLoading()
        XCTAssertEqual(vm.selectedDatabase, updated)
        XCTAssertEqual(vm.selectedDatabase?.kind, .cluster)
    }

    func testMissingRefreshTargetDoesNotFallBackToSameIdentifierOfOtherType() async {
        let probe = RDSStateProbe(rows: ["cluster-2": []])
        let vm = makeVM(probe)
        await load(vm)
        vm.selectedDatabase = rdsStateDatabase(kind: .cluster)
        vm.refresh()
        await vm.waitForLoading()
        XCTAssertTrue(vm.instances.contains(rdsStateDatabase()))
        XCTAssertNil(vm.selectedDatabase)
    }

    func testUserSelectionOrClearPreventsLateRefreshTargetRestoration() async {
        for clearSelection in [false, true] {
            let gate = TestGate()
            let probe = RDSStateProbe(gates: ["cluster-2": gate])
            let vm = makeVM(probe)
            await load(vm)
            vm.selectedDatabase = rdsStateDatabase(kind: .cluster)
            vm.refresh()
            await gate.waitForEntry()
            await eventually { !vm.isInstancesLoading }
            vm.selectedDatabase = clearSelection ? nil : rdsStateDatabase()
            await gate.open()
            await vm.waitForLoading()
            XCTAssertEqual(vm.selectedDatabase, clearSelection ? nil : rdsStateDatabase())
        }
    }

    func testTargetCanBeRestoredAfterItsTypeRefreshFailsThenRetries() async {
        let probe = RDSStateProbe(failures: ["cluster-2"])
        let vm = makeVM(probe)
        await load(vm)
        vm.selectedDatabase = rdsStateDatabase(kind: .cluster)
        vm.refresh()
        await vm.waitForLoading()
        XCTAssertNil(vm.selectedDatabase)
        XCTAssertNotNil(vm.clusterError)
        XCTAssertEqual(vm.instances.count, 2)
        vm.refresh()
        await vm.waitForLoading()
        XCTAssertEqual(vm.selectedDatabase, rdsStateDatabase(kind: .cluster))
        XCTAssertNil(vm.error)
    }

    func testCancellationPreservesCompletedTypeAndSelectionOnlyMarksInFlightType() async {
        for loadingKind in RDSResourceKind.allCases {
            let gate = TestGate()
            let probe = RDSStateProbe(gates: ["\(loadingKind.rawValue)-1": gate])
            let vm = makeVM(probe)
            vm.configure(scope: rdsStateScope())
            vm.refresh()
            await gate.waitForEntry()
            await eventually { loadingKind == .instance ? !vm.isClustersLoading : !vm.isInstancesLoading }
            let selection = vm.databases[0]
            vm.selectedDatabase = selection
            let completedRows = vm.databases
            vm.cancelLoading()
            XCTAssertEqual(vm.databases, completedRows)
            XCTAssertEqual(vm.selectedDatabase, selection)
            XCTAssertFalse(vm.isLoading)
            XCTAssertEqual(vm.instanceError != nil, loadingKind == .instance)
            XCTAssertEqual(vm.clusterError != nil, loadingKind == .cluster)
            await gate.open()
            await eventually { await probe.finished("\(loadingKind.rawValue)-1") }
            await settle()
            XCTAssertEqual(vm.databases, completedRows)
            XCTAssertEqual(vm.selectedDatabase, selection)
        }
    }

    func testCancelWhenNothingIsLoadingDoesNotInventErrorsOrClearData() async {
        let vm = makeVM(RDSStateProbe())
        await load(vm)
        vm.selectedDatabase = vm.databases[0]
        let selected = vm.selectedDatabase
        let rows = vm.databases
        vm.cancelLoading()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.selectedDatabase, selected)
        XCTAssertEqual(vm.databases, rows)
    }

    func testScopeChangesAndResetClearListsSelectionErrorsAndFilters() async {
        let scopes = [rdsStateScope(), rdsStateScope(profile: "other"), rdsStateScope(region: "eu-west-1"),
                      rdsStateScope(account: "444455556666"), rdsStateScope(role: "Other"),
                      rdsStateScope(paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/rds-other"]))]
        let vm = makeVM(RDSStateProbe())
        for scope in scopes {
            vm.configure(scope: scope)
            XCTAssertTrue(vm.databases.isEmpty)
            XCTAssertNil(vm.selectedDatabase)
            XCTAssertNil(vm.error)
            XCTAssertEqual(vm.searchText, "")
            XCTAssertNil(vm.kindFilter)
            XCTAssertFalse(vm.isLoading)
            vm.refresh()
            await vm.waitForLoading()
            vm.selectedDatabase = vm.databases[0]
            vm.searchText = "shared"
            vm.kindFilter = .cluster
        }
        vm.reset()
        XCTAssertNil(vm.scope)
        XCTAssertTrue(vm.databases.isEmpty)
        XCTAssertNil(vm.selectedDatabase)
        XCTAssertNil(vm.kindFilter)
    }

    func testSameScopeConfigureKeepsInFlightQueryAndLoadedState() async {
        let gate = TestGate()
        let probe = RDSStateProbe(gates: ["instance-1": gate])
        let vm = makeVM(probe)
        let scope = rdsStateScope()
        vm.configure(scope: scope)
        vm.refresh()
        await gate.waitForEntry()
        vm.configure(scope: scope)
        XCTAssertTrue(vm.isInstancesLoading)
        await gate.open()
        await vm.waitForLoading()
        vm.selectedDatabase = vm.databases[0]
        vm.searchText = "shared"
        vm.configure(scope: scope)
        XCTAssertNotNil(vm.selectedDatabase)
        XCTAssertEqual(vm.searchText, "shared")
        let counts = await probe.counts()
        XCTAssertEqual(counts, [1, 1])
    }

    func testLateSuccessAndFailureCannotOverwriteScopeRefreshResetOrCancellation() async {
        for kind in RDSResourceKind.allCases {
            for failure in [false, true] {
                for transition in ["scope", "refresh", "reset", "cancel"] {
                    let gate = TestGate()
                    let key = "\(kind.rawValue)-1"
                    let probe = RDSStateProbe(gates: [key: gate], failures: failure ? [key] : [],
                                              rows: [key: [rdsStateDatabase("outdated", kind: kind)]])
                    let vm = makeVM(probe)
                    vm.configure(scope: rdsStateScope())
                    vm.refresh()
                    await gate.waitForEntry()
                    if transition == "scope" { vm.configure(scope: rdsStateScope(profile: "other")) }
                    if transition == "reset" { vm.reset() }
                    else if transition == "cancel" { vm.cancelLoading() }
                    else { vm.refresh(); await vm.waitForLoading() }
                    let expectedRows = vm.databases
                    let expectedInstanceError = vm.instanceError
                    let expectedClusterError = vm.clusterError
                    await gate.open()
                    await eventually { await probe.finished(key) }
                    await settle()
                    XCTAssertEqual(vm.databases, expectedRows, "\(kind)-\(failure)-\(transition)")
                    XCTAssertEqual(vm.instanceError, expectedInstanceError)
                    XCTAssertEqual(vm.clusterError, expectedClusterError)
                    XCTAssertFalse(vm.isLoading)
                }
            }
        }
    }

    func testMalformedRowsFailOnlyTheirOwnType() async {
        let instance = rdsStateDatabase()
        let malformedLists = [[instance, instance], [rdsStateDatabase(kind: .cluster)],
                              [RDSDatabase(arn: "", identifier: "db", kind: .instance)],
                              [RDSDatabase(arn: "arn", identifier: "", kind: .instance)]]
        for malformed in malformedLists {
            let vm = makeVM(RDSStateProbe(rows: ["instance-1": malformed]))
            await load(vm)
            XCTAssertTrue(vm.instances.isEmpty)
            XCTAssertEqual(vm.clusters.count, 2)
            XCTAssertEqual(vm.instanceError, RDSError.invalidResponse.localizedDescription)
            XCTAssertNil(vm.clusterError)
        }
    }

    private func makeVM(_ probe: RDSStateProbe) -> RDSViewModel {
        RDSViewModel(instanceLoader: { try await probe.load(.instance, scope: $0) },
                     clusterLoader: { try await probe.load(.cluster, scope: $0) })
    }

    private func load(_ vm: RDSViewModel) async {
        vm.configure(scope: rdsStateScope())
        vm.refresh()
        await vm.waitForLoading()
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("State transition did not complete", file: file, line: line)
    }
}
