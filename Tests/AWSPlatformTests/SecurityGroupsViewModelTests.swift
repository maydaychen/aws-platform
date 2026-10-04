import XCTest
@testable import AWSPlatform

@MainActor
final class SecurityGroupsViewModelTests: XCTestCase {
    func testNilInvalidScopesAndConfigureAloneNeverQuery() async {
        let probe = SecurityGroupsStateProbe()
        let vm = makeVM(probe)
        for scope in [nil, securityGroupStateScope(account: ""), securityGroupStateScope(region: "invalid")] {
            vm.configure(scope: scope)
            vm.loadIfNeeded()
            vm.refresh()
            await vm.loadGroups()
            XCTAssertFalse(vm.isLoading)
            XCTAssertTrue(vm.groups.isEmpty)
        }
        vm.configure(scope: securityGroupStateScope())
        let calls = await probe.count()
        XCTAssertEqual(calls, 0)
        XCTAssertNil(vm.selectedGroup)
    }

    func testFirstVisitDeduplicatesWithoutAutoSelectionAndSelectionMakesNoNewRequest() async {
        let gate = TestGate()
        let probe = SecurityGroupsStateProbe(firstGate: gate)
        let vm = makeVM(probe)
        vm.configure(scope: securityGroupStateScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        vm.loadIfNeeded()
        let joined = Task { await vm.loadGroups() }
        await Task.yield()
        await gate.open()
        await joined.value
        await vm.waitForLoad()
        XCTAssertNil(vm.selectedGroup)
        XCTAssertEqual(vm.groups.count, 2)
        vm.loadIfNeeded()
        vm.selectedGroup = vm.groups[0]
        XCTAssertEqual(vm.selectedGroup, vm.groups[0])
        let calls = await probe.count()
        XCTAssertEqual(calls, 1)
    }

    func testUnlistedOrModifiedSelectionIsRejected() async {
        let probe = SecurityGroupsStateProbe()
        let vm = makeVM(probe)
        vm.configure(scope: securityGroupStateScope())
        await vm.loadGroups()
        vm.selectedGroup = securityGroupStateRow("sg-99999999")
        XCTAssertNil(vm.selectedGroup)
        vm.selectedGroup = securityGroupStateRow("sg-12345678", name: "forged")
        XCTAssertNil(vm.selectedGroup)
        let calls = await probe.count()
        XCTAssertEqual(calls, 1)
    }

    func testSameScopePreservesPendingRequestFiltersAndSelectedData() async {
        let gate = TestGate()
        let probe = SecurityGroupsStateProbe(firstGate: gate)
        let vm = makeVM(probe)
        let scope = securityGroupStateScope()
        vm.configure(scope: scope)
        vm.loadIfNeeded()
        await gate.waitForEntry()
        vm.searchText = "frontend"
        vm.vpcFilter = "vpc-12345678"
        vm.configure(scope: scope)
        vm.loadIfNeeded()
        XCTAssertTrue(vm.isLoading)
        XCTAssertEqual(vm.searchText, "frontend")
        XCTAssertEqual(vm.vpcFilter, "vpc-12345678")
        await gate.open()
        await vm.waitForLoad()
        vm.selectedGroup = vm.groups[0]
        vm.configure(scope: scope)
        XCTAssertNotNil(vm.selectedGroup)
        let calls = await probe.count()
        XCTAssertEqual(calls, 1)
    }

    func testProfileRegionIdentityAndPathsChangesClearAllState() async {
        let probe = SecurityGroupsStateProbe()
        let vm = makeVM(probe)
        let scopes = [securityGroupStateScope(), securityGroupStateScope(profile: "other"),
                      securityGroupStateScope(region: "eu-west-1"), securityGroupStateScope(account: "444455556666"),
                      securityGroupStateScope(role: "OtherRole"),
                      securityGroupStateScope(paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/sg-other-config"])),
                      securityGroupStateScope(paths: AWSConfigurationPaths(environment: ["AWS_SHARED_CREDENTIALS_FILE": "/tmp/sg-other-credentials"]))]
        for (index, scope) in scopes.enumerated() {
            vm.configure(scope: scope)
            XCTAssertTrue(vm.groups.isEmpty)
            XCTAssertNil(vm.selectedGroup)
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isStale)
            XCTAssertEqual(vm.searchText, "")
            XCTAssertEqual(vm.vpcFilter, "All")
            let calls = await probe.count()
            XCTAssertEqual(calls, index)
            vm.loadIfNeeded()
            await vm.waitForLoad()
            vm.selectedGroup = vm.groups[0]
            vm.searchText = "frontend"
            vm.vpcFilter = "vpc-12345678"
        }
        vm.configure(scope: nil)
        vm.loadIfNeeded()
        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertNil(vm.selectedGroup)
        let calls = await probe.count()
        XCTAssertEqual(calls, scopes.count)
    }

    func testLocalSearchIncludesMetadataTagsRulesAndReferencesWithVPCFilter() async {
        let first = SecurityGroupModel(
            id: "sg-12345678", name: "frontend", ownerID: "111122223333", vpcID: "vpc-12345678", description: "Production web tier",
            inboundRules: [SecurityGroupRule(protocolName: "TCP", portRange: "443", target: "sg-87654321", description: "App access",
                                              referencedGroupID: "sg-87654321", referencedAccountID: "444455556666",
                                              fields: [ELBField(name: "Target type", value: "Security group")])],
            outboundRules: [SecurityGroupRule(protocolName: "ICMPv6", portRange: "Type 128 / Code 0", target: "2001:db8::/32")],
            tags: [ELBField(name: "Environment", value: "production")]
        )
        let second = securityGroupStateRow("sg-aaaaaaaa", name: "database", vpc: "vpc-87654321")
        let probe = SecurityGroupsStateProbe(results: [[first, second]])
        let vm = makeVM(probe)
        vm.configure(scope: securityGroupStateScope())
        await vm.loadGroups()
        XCTAssertEqual(vm.availableVPCs, ["All", "vpc-12345678", "vpc-87654321"])
        for search in [" FRONTEND ", "sg-12345678", "Production web", "Environment", "App access", "TCP", "443",
                       "sg-87654321", "444455556666", "target type", "Security group", "ICMPV6", "Type 128", "2001:db8"] {
            vm.searchText = search
            XCTAssertEqual(vm.filteredGroups, [first], search)
        }
        vm.searchText = "111122223333"
        XCTAssertEqual(vm.filteredGroups, [first, second])
        vm.vpcFilter = "vpc-12345678"
        XCTAssertEqual(vm.filteredGroups, [first])
        vm.vpcFilter = "VPC-87654321"
        XCTAssertEqual(vm.filteredGroups, [second])
        vm.searchText = ""
        XCTAssertEqual(vm.filteredGroups, [second])
        vm.searchText = "frontend"
        XCTAssertTrue(vm.filteredGroups.isEmpty)
        let calls = await probe.count()
        XCTAssertEqual(calls, 1)
    }

    func testVisibleSharedOwnerGroupIsPreservedAndSelectable() async {
        let shared = SecurityGroupModel(id: "sg-12345678", name: "shared", ownerID: "444455556666")
        let probe = SecurityGroupsStateProbe(results: [[shared]])
        let vm = makeVM(probe)
        vm.configure(scope: securityGroupStateScope())
        await vm.loadGroups()
        XCTAssertEqual(vm.groups, [shared])
        vm.selectedGroup = shared
        XCTAssertEqual(vm.selectedGroup?.ownerID, "444455556666")
        XCTAssertNil(vm.error)
    }

    func testEmptyAndFailedInitialLoadDoNotAutoRetryOnReentry() async {
        for failure in [false, true] {
            let probe = SecurityGroupsStateProbe(results: [[]], failures: failure ? [1] : [])
            let vm = makeVM(probe)
            vm.configure(scope: securityGroupStateScope())
            vm.loadIfNeeded()
            await vm.waitForLoad()
            vm.loadIfNeeded()
            let calls = await probe.count()
            XCTAssertEqual(calls, 1)
            XCTAssertFalse(vm.isStale)
            XCTAssertEqual(vm.error != nil, failure)
            await vm.loadGroups()
            XCTAssertNil(vm.error)
        }
    }

    func testFailedRefreshPreservesPreviousSnapshotAndSelectionWithStaleMarker() async {
        for rows in [[], [securityGroupStateRow("sg-12345678")]] {
            let probe = SecurityGroupsStateProbe(results: [rows], failures: [2])
            let vm = makeVM(probe)
            vm.configure(scope: securityGroupStateScope())
            await vm.loadGroups()
            vm.selectedGroup = vm.groups.first
            let selected = vm.selectedGroup
            await vm.loadGroups()
            XCTAssertEqual(vm.groups, rows)
            XCTAssertEqual(vm.selectedGroup, selected)
            XCTAssertTrue(vm.isStale)
            XCTAssertTrue(vm.error?.contains("previous security group list") == true)
            await vm.loadGroups()
            XCTAssertFalse(vm.isStale)
            XCTAssertNil(vm.error)
        }
    }

    func testRefreshReplacesMatchingSelectedGroupAndClearsDeletedSelectionAndFilter() async {
        let original = securityGroupStateRow("sg-12345678")
        let updated = securityGroupStateRow("sg-12345678", name: "updated", vpc: "vpc-87654321")
        let probe = SecurityGroupsStateProbe(results: [[original], [updated], []])
        let vm = makeVM(probe)
        vm.configure(scope: securityGroupStateScope())
        await vm.loadGroups()
        vm.selectedGroup = original
        vm.vpcFilter = "vpc-12345678"
        await vm.loadGroups()
        XCTAssertEqual(vm.selectedGroup, updated)
        XCTAssertEqual(vm.vpcFilter, "All")
        await vm.loadGroups()
        XCTAssertNil(vm.selectedGroup)
        XCTAssertTrue(vm.groups.isEmpty)
    }

    func testLateSuccessAndFailureCannotCrossScopeResetOrCancellation() async {
        for shouldFail in [false, true] {
            for change in ["scope", "reset", "cancel"] {
                let gate = TestGate()
                let probe = SecurityGroupsStateProbe(results: [[securityGroupStateRow("sg-11111111")], [securityGroupStateRow("sg-22222222")]],
                                                       firstGate: gate, failures: shouldFail ? [1] : [])
                let vm = makeVM(probe)
                vm.configure(scope: securityGroupStateScope())
                vm.loadIfNeeded()
                await gate.waitForEntry()
                let waiting = Task { await vm.waitForLoad() }
                await Task.yield()
                switch change {
                case "scope":
                    vm.configure(scope: securityGroupStateScope(region: "eu-west-1"))
                    await vm.loadGroups()
                case "reset": vm.reset()
                default: vm.cancel()
                }
                await gate.open()
                await waiting.value
                XCTAssertEqual(vm.groups.map(\.id), change == "scope" ? ["sg-22222222"] : [])
                XCTAssertFalse(vm.isLoading)
                XCTAssertFalse(vm.isStale)
                if change == "cancel" { XCTAssertTrue(vm.error?.contains("cancelled") == true) }
                else { XCTAssertNil(vm.error) }
            }
        }
    }

    func testNewRefreshWinsOverPendingOldRequestInSameScope() async {
        let gate = TestGate()
        let probe = SecurityGroupsStateProbe(results: [[securityGroupStateRow("sg-11111111")], [securityGroupStateRow("sg-22222222")]], firstGate: gate)
        let vm = makeVM(probe)
        vm.configure(scope: securityGroupStateScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        let waiting = Task { await vm.waitForLoad() }
        await Task.yield()
        vm.refresh()
        await vm.waitForLoad()
        await gate.open()
        await waiting.value
        XCTAssertEqual(vm.groups.map(\.id), ["sg-22222222"])
        XCTAssertNil(vm.error)
    }

    func testImmediateCancellationAndAlreadyCancelledCallerMakeNoRequests() async {
        let probe = SecurityGroupsStateProbe()
        let vm = makeVM(probe)
        vm.configure(scope: securityGroupStateScope())
        vm.loadIfNeeded()
        vm.cancel()
        await Task.yield()
        let cancelled = Task { await vm.loadGroups() }
        cancelled.cancel()
        await cancelled.value
        let calls = await probe.count()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertTrue(vm.error?.contains("cancelled") == true)
    }

    func testCancelledOwnedCallerInvalidatesItsLateResult() async {
        let gate = TestGate()
        let probe = SecurityGroupsStateProbe(firstGate: gate)
        let vm = makeVM(probe)
        vm.configure(scope: securityGroupStateScope())
        let caller = Task { await vm.loadGroups() }
        await gate.waitForEntry()
        caller.cancel()
        await Task.yield()
        await gate.open()
        await caller.value
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertTrue(vm.error?.contains("cancelled") == true)
    }

    func testCancelledOldCallerDoesNotCancelNewerRefresh() async {
        let first = TestGate()
        let second = TestGate()
        let probe = SecurityGroupsStateProbe(firstGate: first, secondGate: second)
        let vm = makeVM(probe)
        vm.configure(scope: securityGroupStateScope())
        let caller = Task { await vm.loadGroups() }
        await first.waitForEntry()
        vm.refresh()
        await second.waitForEntry()
        caller.cancel()
        await first.open()
        await caller.value
        XCTAssertTrue(vm.isLoading)
        await second.open()
        await vm.waitForLoad()
        XCTAssertFalse(vm.groups.isEmpty)
        XCTAssertNil(vm.error)
    }

    func testCancelledSharedWaiterDoesNotCancelExistingRequest() async {
        let gate = TestGate()
        let probe = SecurityGroupsStateProbe(firstGate: gate)
        let vm = makeVM(probe)
        vm.configure(scope: securityGroupStateScope())
        vm.refresh()
        await gate.waitForEntry()
        let caller = Task { await vm.loadGroups() }
        await Task.yield()
        caller.cancel()
        await Task.yield()
        XCTAssertTrue(vm.isLoading)
        await gate.open()
        await caller.value
        await vm.waitForLoad()
        XCTAssertFalse(vm.groups.isEmpty)
        XCTAssertNil(vm.error)
    }

    func testUnknownErrorsAreSanitizedAndKnownErrorsRemainActionable() async {
        let vm = SecurityGroupsViewModel { _ in throw SecurityGroupsStateUnknownError.failed }
        vm.configure(scope: securityGroupStateScope())
        await vm.loadGroups()
        XCTAssertEqual(vm.error, "Unable to load security groups. Refresh to try again.")
        for error in [SecurityGroupError.permission, .credentials, .throttled] {
            let known = SecurityGroupsViewModel { _ in throw error }
            known.configure(scope: securityGroupStateScope())
            await known.loadGroups()
            XCTAssertEqual(known.error, error.localizedDescription)
        }
    }

    func testInvalidOrDuplicateIDsRejectEntireResult() async {
        let row = securityGroupStateRow("sg-12345678")
        for rows in [[securityGroupStateRow("sg-invalid")], [row, row]] {
            let probe = SecurityGroupsStateProbe(results: [rows])
            let vm = makeVM(probe)
            vm.configure(scope: securityGroupStateScope())
            await vm.loadGroups()
            XCTAssertTrue(vm.groups.isEmpty)
            XCTAssertEqual(vm.error, SecurityGroupError.invalidResponse.localizedDescription)
        }
    }

    private func makeVM(_ probe: SecurityGroupsStateProbe) -> SecurityGroupsViewModel {
        SecurityGroupsViewModel { try await probe.load($0) }
    }
}

private func securityGroupStateScope(
    profile: String = "work", account: String = "111122223333", region: String = "us-east-1", role: String = "ReadOnly",
    paths: AWSConfigurationPaths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/sg-config"])
) -> MonitoringScope {
    MonitoringScope(profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
                    identity: AWSIdentity(account: account, arn: "arn:aws:sts::\(account):assumed-role/\(role)/test", userID: "test"),
                    region: region, paths: paths)
}

private func securityGroupStateRow(_ id: String, name: String = "frontend", vpc: String = "vpc-12345678") -> SecurityGroupModel {
    SecurityGroupModel(id: id, name: name, ownerID: "111122223333", vpcID: vpc)
}

private enum SecurityGroupsStateUnknownError: LocalizedError {
    case failed
    var errorDescription: String? { "sensitive-test-marker must not be displayed" }
}

private actor SecurityGroupsStateProbe {
    private var calls = 0
    private let results: [[SecurityGroupModel]]
    private let firstGate: TestGate?
    private let secondGate: TestGate?
    private let failures: Set<Int>

    init(results: [[SecurityGroupModel]] = [[securityGroupStateRow("sg-12345678"), securityGroupStateRow("sg-87654321", name: "database")]],
         firstGate: TestGate? = nil, secondGate: TestGate? = nil, failures: Set<Int> = []) {
        self.results = results
        self.firstGate = firstGate
        self.secondGate = secondGate
        self.failures = failures
    }
    func count() -> Int { calls }
    func load(_ scope: MonitoringScope) async throws -> [SecurityGroupModel] {
        calls += 1
        let call = calls
        if call == 1 { await firstGate?.wait() }
        if call == 2 { await secondGate?.wait() }
        if failures.contains(call) { throw SecurityGroupError.invalidResponse }
        return results[min(call - 1, results.count - 1)]
    }
}
