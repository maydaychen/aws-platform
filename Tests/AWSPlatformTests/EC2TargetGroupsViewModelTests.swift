import XCTest
@testable import AWSPlatform

@MainActor
final class EC2TargetGroupsViewModelTests: XCTestCase {
    func testConfigureNeverLoadsAndNilInvalidScopesAndInstancesMakeNoCalls() async {
        let probe = MembershipStateProbe()
        let vm = makeVM(probe)
        vm.load()
        vm.refresh()
        vm.configure(scope: elbStateScope(), instanceID: "i-12345678")
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.result)
        var counts = await probe.count()
        XCTAssertEqual(counts, 0)
        for scope in [nil, elbStateScope(account: "")] {
            vm.configure(scope: scope, instanceID: "i-12345678")
            vm.load()
            await vm.waitForLoad()
        }
        for id in [nil, "", "192.0.2.1", "i-not-valid", "i-12345678 extra", "i-12345678\n"] {
            vm.configure(scope: elbStateScope(), instanceID: id)
            vm.refresh()
            await vm.waitForLoad()
        }
        counts = await probe.count()
        XCTAssertEqual(counts, 0)
    }

    func testManualLoadDeduplicatesAndSameConfigurationPreservesPendingAndCompletedResult() async {
        let gate = TestGate()
        let probe = MembershipStateProbe(gate: gate)
        let vm = makeVM(probe)
        let scope = elbStateScope()
        vm.configure(scope: scope, instanceID: "i-12345678")
        vm.load()
        await gate.waitForEntry()
        vm.load()
        vm.configure(scope: scope, instanceID: "i-12345678")
        XCTAssertTrue(vm.isLoading)
        await gate.open()
        await vm.waitForLoad()
        let result = vm.result
        XCTAssertEqual(result?.matches.count, 1)
        XCTAssertEqual(result?.matches.first?.targets.count, 2)
        XCTAssertEqual(result?.matches.first?.targets.map(\.port), [8080, 8443])
        vm.configure(scope: scope, instanceID: "i-12345678")
        XCTAssertEqual(vm.result, result)
        let count = await probe.count()
        XCTAssertEqual(count, 1)
    }

    func testPartialMembershipResultRemainsExplicitlyPartialWithMatchesAndFailures() async {
        let probe = MembershipStateProbe(partial: true)
        let vm = makeVM(probe)
        vm.configure(scope: elbStateScope(), instanceID: "i-12345678")
        vm.load()
        await vm.waitForLoad()
        XCTAssertEqual(vm.result?.checkedGroupCount, 2)
        XCTAssertEqual(vm.result?.totalGroupCount, 3)
        XCTAssertEqual(vm.result?.matches.count, 1)
        XCTAssertEqual(vm.result?.failures.count, 1)
        XCTAssertEqual(vm.result?.isComplete, false)
        XCTAssertEqual(vm.result?.matches.first?.targets.first?.state, "unhealthy")
        XCTAssertNil(vm.error)
    }

    func testEmptyCompleteMembershipResultIsValid() async {
        let vm = EC2TargetGroupsViewModel { _, _ in ELBMembershipResult(checkedGroupCount: 0, totalGroupCount: 0) }
        vm.configure(scope: elbStateScope(), instanceID: "i-12345678")
        vm.load()
        await vm.waitForLoad()
        XCTAssertEqual(vm.result?.isComplete, true)
        XCTAssertEqual(vm.result?.matches, [])
        XCTAssertNil(vm.error)
    }

    func testChangingInstanceProfileRegionOrPathsClearsWithoutAutoReloading() async {
        let probe = MembershipStateProbe()
        let vm = makeVM(probe)
        let configurations = [(elbStateScope(), "i-12345678"), (elbStateScope(), "i-87654321"),
                              (elbStateScope(profile: "other"), "i-87654321"),
                              (elbStateScope(region: "eu-west-1"), "i-87654321"),
                              (elbStateScope(paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/elb-reverse-other"])), "i-87654321")]
        for (index, configuration) in configurations.enumerated() {
            vm.configure(scope: configuration.0, instanceID: configuration.1)
            XCTAssertNil(vm.result)
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
            let count = await probe.count()
            XCTAssertEqual(count, index)
            vm.load()
            await vm.waitForLoad()
            XCTAssertNotNil(vm.result)
        }
    }

    func testLateSuccessAndFailureCannotCrossInstanceScopeResetOrCancel() async {
        for fail in [false, true] {
            for change in ["instance", "scope", "reset", "cancel"] {
                let gate = TestGate()
                let probe = MembershipStateProbe(gate: gate, failures: fail ? [1] : [])
                let vm = makeVM(probe)
                vm.configure(scope: elbStateScope(), instanceID: "i-12345678")
                vm.load()
                await gate.waitForEntry()
                let waiting = Task { await vm.waitForLoad() }
                await Task.yield()
                switch change {
                case "instance":
                    vm.configure(scope: elbStateScope(), instanceID: "i-87654321")
                    vm.load()
                    await vm.waitForLoad()
                case "scope":
                    vm.configure(scope: elbStateScope(region: "eu-west-1"), instanceID: "i-12345678")
                    vm.load()
                    await vm.waitForLoad()
                case "reset": vm.reset()
                default: vm.cancel()
                }
                await gate.open()
                await waiting.value
                switch change {
                case "instance": XCTAssertEqual(vm.result?.matches.first?.targets.first?.targetID, "i-87654321")
                case "scope": XCTAssertTrue(vm.result?.matches.first?.group.arn.contains(":eu-west-1:") == true)
                default: XCTAssertNil(vm.result)
                }
                XCTAssertFalse(vm.isLoading)
                if change == "cancel" { XCTAssertTrue(vm.error?.contains("cancelled") == true) }
                else { XCTAssertNil(vm.error) }
            }
        }
    }

    func testImmediateCancellationNeverCallsLoaderAndRetryIsManual() async {
        let probe = MembershipStateProbe()
        let vm = makeVM(probe)
        vm.configure(scope: elbStateScope(), instanceID: "i-12345678")
        vm.load()
        vm.cancel()
        await Task.yield()
        let count = await probe.count()
        XCTAssertEqual(count, 0)
        XCTAssertNil(vm.result)
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.error?.contains("cancelled") == true)
        vm.configure(scope: elbStateScope(), instanceID: "i-12345678")
        XCTAssertTrue(vm.error?.contains("cancelled") == true)
        vm.refresh()
        await vm.waitForLoad()
        XCTAssertNotNil(vm.result)
        XCTAssertNil(vm.error)
    }

    func testRefreshSupersedesPendingScanAndLateFailureCannotReplaceResult() async {
        let gate = TestGate()
        let probe = MembershipStateProbe(gate: gate, failures: [1])
        let vm = makeVM(probe)
        vm.configure(scope: elbStateScope(), instanceID: "i-12345678")
        vm.load()
        await gate.waitForEntry()
        let waiting = Task { await vm.waitForLoad() }
        await Task.yield()
        vm.refresh()
        await vm.waitForLoad()
        await gate.open()
        await waiting.value
        XCTAssertNotNil(vm.result)
        XCTAssertNil(vm.error)
        let count = await probe.count()
        XCTAssertEqual(count, 2)
    }

    func testUnknownErrorsAreSanitizedAndFailureDoesNotAutoRetry() async {
        let probe = MembershipStateProbe(failures: [1], unknownError: true)
        let vm = makeVM(probe)
        vm.configure(scope: elbStateScope(), instanceID: "i-12345678")
        vm.load()
        await vm.waitForLoad()
        XCTAssertEqual(vm.error, "Unable to find target group memberships. Refresh to try again.")
        vm.configure(scope: elbStateScope(), instanceID: "i-12345678")
        let count = await probe.count()
        XCTAssertEqual(count, 1)
        vm.load()
        await vm.waitForLoad()
        XCTAssertNil(vm.error)
        XCTAssertNotNil(vm.result)
    }

    func testKnownPermissionsErrorsStayActionable() async {
        let vm = EC2TargetGroupsViewModel { _, _ in throw AWSELBService.RequestError.targetHealthPermission }
        vm.configure(scope: elbStateScope(), instanceID: "i-12345678")
        vm.load()
        await vm.waitForLoad()
        XCTAssertEqual(vm.error, AWSELBService.RequestError.targetHealthPermission.localizedDescription)
    }

    func testMismatchedMembershipScopeInstanceTypeAndInvalidCountersAreRejected() async {
        let scope = elbStateScope()
        let target = ELBTargetHealth(targetID: "i-12345678", port: 80, state: "healthy")
        let group = elbStateGroup("one")
        let invalidResults = [
            ELBMembershipResult(matches: [ELBMembership(group: elbStateGroup("one", scope: elbStateScope(region: "eu-west-1")), targets: [target])], checkedGroupCount: 1, totalGroupCount: 1),
            ELBMembershipResult(matches: [ELBMembership(group: group, targets: [ELBTargetHealth(targetID: "i-87654321", state: "healthy")])], checkedGroupCount: 1, totalGroupCount: 1),
            ELBMembershipResult(matches: [ELBMembership(group: elbStateGroup("one", type: "ip"), targets: [target])], checkedGroupCount: 1, totalGroupCount: 1),
            ELBMembershipResult(matches: [ELBMembership(group: group, targets: [])], checkedGroupCount: 1, totalGroupCount: 1),
            ELBMembershipResult(matches: [ELBMembership(group: group, targets: [ELBTargetHealth(targetID: "i-12345678", state: "unused", reason: "Target.NotRegistered")])], checkedGroupCount: 1, totalGroupCount: 1),
            ELBMembershipResult(checkedGroupCount: -1, totalGroupCount: 1),
            ELBMembershipResult(checkedGroupCount: 2, totalGroupCount: 1)
        ]
        for result in invalidResults {
            let vm = EC2TargetGroupsViewModel { _, _ in result }
            vm.configure(scope: scope, instanceID: "i-12345678")
            vm.load()
            await vm.waitForLoad()
            XCTAssertNil(vm.result)
            XCTAssertEqual(vm.error, ELBError.invalidResponse.localizedDescription)
        }
    }

    private func makeVM(_ probe: MembershipStateProbe) -> EC2TargetGroupsViewModel {
        EC2TargetGroupsViewModel { try await probe.load($0, $1) }
    }
}

private enum MembershipStateUnknownError: LocalizedError {
    case failed
    var errorDescription: String? { "sensitive-test-marker must not be displayed" }
}

private actor MembershipStateProbe {
    private var calls = 0
    private let gate: TestGate?
    private let failures: Set<Int>
    private let partial: Bool
    private let unknownError: Bool
    init(gate: TestGate? = nil, failures: Set<Int> = [], partial: Bool = false, unknownError: Bool = false) {
        self.gate = gate
        self.failures = failures
        self.partial = partial
        self.unknownError = unknownError
    }
    func count() -> Int { calls }
    func load(_ scope: MonitoringScope, _ instanceID: String) async throws -> ELBMembershipResult {
        calls += 1
        let call = calls
        if call == 1 { await gate?.wait() }
        if failures.contains(call) {
            if unknownError { throw MembershipStateUnknownError.failed }
            throw ELBError.invalidResponse
        }
        let targets = [ELBTargetHealth(targetID: instanceID, port: 8080, state: "unhealthy"),
                       ELBTargetHealth(targetID: instanceID, port: 8443, state: "healthy")]
        return ELBMembershipResult(matches: [ELBMembership(group: elbStateGroup("one", scope: scope), targets: targets)],
                                   checkedGroupCount: 2, totalGroupCount: partial ? 3 : 2,
                                   failures: partial ? [ELBField(name: "restricted-group", value: "Target health access denied.")] : [])
    }
}
