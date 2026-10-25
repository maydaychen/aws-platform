import XCTest
@testable import AWSPlatform

@MainActor
final class EBSViewModelTests: XCTestCase {
    func testNoScopeAndConfigureAloneNeverLoad() async {
        let probe = EBSStateProbe()
        let vm = makeVM(probe)
        vm.refresh(); vm.loadIfNeeded(); await vm.loadResources()
        vm.configure(scope: ebsScope(region: "invalid")); await vm.loadResources()
        vm.configure(scope: ebsScope())
        let calls = await probe.count
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(vm.resources.isEmpty)
        XCTAssertNil(vm.selectedResource)
    }

    func testFirstVisitLoadsOnceWithoutSelectingResource() async {
        let gate = TestGate()
        let probe = EBSStateProbe(gate: gate)
        let vm = makeVM(probe)
        vm.configure(scope: ebsScope()); vm.loadIfNeeded()
        await gate.waitForEntry()
        vm.loadIfNeeded()
        let joined = Task { await vm.loadResources() }
        await Task.yield(); await gate.open(); await joined.value
        vm.loadIfNeeded()
        let calls = await probe.count
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(vm.resources, [ebsRow()])
        XCTAssertNil(vm.selectedResource)
        XCTAssertFalse(vm.isLoading)
    }

    func testProfileRegionRoleAndConfigChangesClearDataAndFilters() async {
        let probe = EBSStateProbe()
        let vm = makeVM(probe)
        for scope in [ebsScope(), ebsScope(profile: "other"), ebsScope(region: "eu-west-1"), ebsScope(role: "OtherRole"),
                      ebsScope(config: "/tmp/ebs-other-offline-config"), ebsScope(account: "444455556666")] {
            vm.configure(scope: scope)
            XCTAssertTrue(vm.resources.isEmpty)
            XCTAssertNil(vm.selectedResource)
            XCTAssertEqual(vm.searchText, "")
            XCTAssertEqual(vm.stateFilter, "All")
            await vm.loadResources()
            vm.selectedResource = vm.resources.first
            XCTAssertNotNil(vm.selectedResource)
            vm.searchText = "hidden"; vm.stateFilter = "available"
        }
        vm.configure(scope: nil)
        XCTAssertTrue(vm.resources.isEmpty)
        XCTAssertNil(vm.selectedResource)
    }

    func testLateSuccessAndFailureCannotAffectNewScope() async {
        for fail in [false, true] {
            let gate = TestGate()
            let vm = EBSViewModel(kind: .volume) { _, scope in
                if scope.profile.name == "ebs-test" {
                    await gate.wait()
                    if fail { throw EBSError.volumesPermission }
                }
                return [ebsRow(name: scope.profile.name)]
            }
            vm.configure(scope: ebsScope()); vm.loadIfNeeded(); await gate.waitForEntry()
            vm.configure(scope: ebsScope(profile: "new")); await vm.loadResources()
            await gate.open()
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(vm.resources.first?.name, "new")
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testCancelRejectsLateSuccessAndRetryWorks() async {
        let gate = TestGate()
        let probe = EBSStateProbe(gate: gate)
        let vm = makeVM(probe)
        vm.configure(scope: ebsScope()); vm.refresh(); await gate.waitForEntry()
        vm.cancel(); await gate.open()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(vm.resources.isEmpty)
        XCTAssertEqual(vm.error, EBSError.cancelled.rawValue)
        await vm.loadResources()
        XCTAssertEqual(vm.resources.count, 1)
        XCTAssertNil(vm.error)
    }

    func testRefreshPreservesSelectionUpdatesMetadataAndClearsRemovedSelection() async {
        let probe = EBSStateProbe()
        let vm = makeVM(probe)
        vm.configure(scope: ebsScope()); await vm.loadResources()
        vm.selectedResource = vm.resources[0]
        await probe.set(rows: [ebsRow(name: "updated")])
        await vm.loadResources()
        XCTAssertEqual(vm.selectedResource?.name, "updated")
        await probe.set(rows: [])
        await vm.loadResources()
        XCTAssertNil(vm.selectedResource)
    }

    func testRefreshFailureKeepsExplicitlyStaleListAndRecoveryClearsError() async {
        let probe = EBSStateProbe()
        let vm = makeVM(probe)
        vm.configure(scope: ebsScope()); await vm.loadResources()
        vm.selectedResource = vm.resources[0]
        await probe.set(error: .volumesPermission)
        await vm.loadResources()
        XCTAssertTrue(vm.isStale)
        XCTAssertEqual(vm.resources, [ebsRow()])
        XCTAssertNotNil(vm.selectedResource)
        XCTAssertEqual(vm.error, EBSError.volumesPermission.rawValue)
        await probe.set(error: nil); await vm.loadResources()
        XCTAssertFalse(vm.isStale); XCTAssertNil(vm.error)
    }

    func testInitialFailureIsNotAnEmptySuccess() async {
        let vm = EBSViewModel(kind: .snapshot) { _, _ in throw EBSError.snapshotsPermission }
        vm.configure(scope: ebsScope()); await vm.loadResources()
        XCTAssertTrue(vm.resources.isEmpty)
        XCTAssertFalse(vm.isStale)
        XCTAssertEqual(vm.error, EBSError.snapshotsPermission.rawValue)
    }

    func testWrongKindOwnerDuplicateAndUnlistedSelectionAreRejected() async {
        for rows in [[ebsRow(.snapshot)], [ebsRow(account: "444455556666")], [ebsRow(), ebsRow()]] {
            let vm = EBSViewModel(kind: .volume) { _, _ in rows }
            vm.configure(scope: ebsScope()); await vm.loadResources()
            XCTAssertEqual(vm.error, EBSError.invalidResponse.rawValue)
            XCTAssertTrue(vm.resources.isEmpty)
        }
        let vm = EBSViewModel(kind: .volume) { _, _ in [ebsRow()] }
        vm.configure(scope: ebsScope()); await vm.loadResources()
        vm.selectedResource = ebsRow(name: "forged")
        XCTAssertNil(vm.selectedResource)
    }

    func testStateAndMetadataSearchIncludeTagsAndAttachments() async {
        var volume = ebsRow()
        volume.attachments = [.init(instanceID: "i-12345678", device: "/dev/sdf", state: "attached", deleteOnTermination: nil)]
        let rows = [volume, ebsRow(id: "vol-87654321", name: "backup")]
        let vm = EBSViewModel(kind: .volume) { _, _ in rows }
        vm.configure(scope: ebsScope()); await vm.loadResources()
        for query in ["i-12345678", "/dev/sdf", "data"] {
            vm.searchText = query
            XCTAssertEqual(vm.filteredResources.map(\.id), [volume.id])
        }
        vm.searchText = "Environment"
        XCTAssertEqual(vm.filteredResources.count, 2)
        vm.stateFilter = "in-use"
        XCTAssertTrue(vm.filteredResources.isEmpty)
    }

    func testVolumeAndSnapshotViewModelsLoadIndependently() async {
        let volume = EBSViewModel(kind: .volume) { kind, _ in XCTAssertEqual(kind, .volume); return [ebsRow()] }
        let snapshot = EBSViewModel(kind: .snapshot) { kind, _ in XCTAssertEqual(kind, .snapshot); return [ebsRow(.snapshot)] }
        volume.configure(scope: ebsScope()); snapshot.configure(scope: ebsScope())
        await volume.loadResources()
        XCTAssertTrue(snapshot.resources.isEmpty)
        await snapshot.loadResources()
        volume.reset()
        XCTAssertEqual(snapshot.resources.count, 1)
    }

    private func makeVM(_ probe: EBSStateProbe) -> EBSViewModel { EBSViewModel(kind: .volume) { try await probe.load($0, scope: $1) } }
}

private actor EBSStateProbe {
    var count = 0
    private let gate: TestGate?
    private var rows = [ebsRow()]
    private var error: EBSError?
    init(gate: TestGate? = nil) { self.gate = gate }
    func set(rows: [EBSResource]) { self.rows = rows }
    func set(error: EBSError?) { self.error = error }
    func load(_ kind: EBSResource.Kind, scope: MonitoringScope) async throws -> [EBSResource] {
        count += 1
        if count == 1 { await gate?.wait() }
        if let error { throw error }
        return rows.map { row in
            var result = ebsRow(kind, id: row.id, name: row.name, account: scope.accountID)
            result.tags = row.tags
            return result
        }
    }
}
