import XCTest
@testable import AWSPlatform

@MainActor
final class AlarmViewModelTests: XCTestCase {
    func testUnconfiguredAndConfigureDoNotQuery() async {
        let probe = AlarmProbe()
        let vm = makeViewModel(probe)
        vm.loadIfNeeded()
        vm.refresh()
        vm.refreshDetails()
        await vm.loadAlarms()
        vm.configure(scope: alarmScope())
        let calls = await probe.counts()
        XCTAssertEqual(calls, [0, 0, 0])
        XCTAssertNil(vm.selectedAlarm)
        XCTAssertFalse(vm.isLoading)
    }

    func testFirstVisitDeduplicatesAndNeverAutoSelectsOrEnriches() async {
        let gate = TestGate()
        let probe = AlarmProbe(firstListGate: gate)
        let vm = makeViewModel(probe)
        vm.configure(scope: alarmScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        vm.loadIfNeeded()
        let joined = Task { await vm.loadAlarms() }
        await Task.yield()
        await gate.open()
        await joined.value
        await vm.waitForCurrentLoad()
        vm.loadIfNeeded()
        let calls = await probe.counts()
        XCTAssertEqual(calls, [1, 0, 0])
        XCTAssertEqual(vm.alarms.count, 2)
        XCTAssertNil(vm.selectedAlarm)
    }

    func testSelectionStartsIndependentTagsAndHistoryOnce() async {
        let probe = AlarmProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: alarmScope())
        await vm.loadAlarms()
        vm.selectedAlarm = vm.alarms.first
        await vm.waitForDetails()
        vm.selectedAlarm = vm.alarms.first
        await vm.waitForDetails()
        let calls = await probe.counts()
        XCTAssertEqual(calls, [1, 1, 1])
        XCTAssertEqual(vm.tags["Name"], "cpu")
        XCTAssertEqual(vm.history.first?.summary, "cpu")
        XCTAssertFalse(vm.isTagsLoading)
        XCTAssertFalse(vm.isHistoryLoading)
    }

    func testUnlistedAlarmCannotTriggerEnrichment() async {
        let probe = AlarmProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: alarmScope())
        await vm.loadAlarms()
        vm.selectedAlarm = makeAlarm("unlisted")
        await vm.waitForDetails()
        let calls = await probe.counts()
        XCTAssertNil(vm.selectedAlarm)
        XCTAssertEqual(calls, [1, 0, 0])
    }

    func testFailureDoesNotAutoRetryOnReentryButExplicitLoadRetries() async {
        let probe = AlarmProbe(listFailures: [1])
        let vm = makeViewModel(probe)
        vm.configure(scope: alarmScope())
        vm.loadIfNeeded()
        await vm.waitForCurrentLoad()
        XCTAssertNotNil(vm.error)
        vm.loadIfNeeded()
        let firstCalls = await probe.counts()
        XCTAssertEqual(firstCalls, [1, 0, 0])
        await vm.loadAlarms()
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.alarms.count, 2)
        let finalCalls = await probe.counts()
        XCTAssertEqual(finalCalls, [2, 0, 0])
    }

    func testCancelledListCannotPublishAndReentryDoesNotRetry() async {
        let gate = TestGate()
        let probe = AlarmProbe(firstListGate: gate)
        let vm = makeViewModel(probe)
        vm.configure(scope: alarmScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        let waiting = Task { await vm.waitForCurrentLoad() }
        await Task.yield()
        vm.cancelLoading()
        await gate.open()
        await waiting.value
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.alarms.isEmpty)
        XCTAssertNotNil(vm.error)
        vm.loadIfNeeded()
        let firstCalls = await probe.counts()
        XCTAssertEqual(firstCalls, [1, 0, 0])
        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.alarms.count, 2)
        XCTAssertNil(vm.error)
    }

    func testProfileRegionIdentityAndConfigChangeResetAllState() async {
        let probe = AlarmProbe()
        let vm = makeViewModel(probe)
        let scopes = [
            alarmScope(), alarmScope(region: "eu-west-1"), alarmScope(profile: "personal"),
            alarmScope(account: "444455556666"), alarmScope(role: "AnotherRole"),
            alarmScope(paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/other-config"]))
        ]
        for scope in scopes {
            vm.configure(scope: scope)
            XCTAssertTrue(vm.alarms.isEmpty)
            XCTAssertNil(vm.selectedAlarm)
            XCTAssertTrue(vm.tags.isEmpty)
            XCTAssertTrue(vm.history.isEmpty)
            XCTAssertEqual(vm.searchText, "")
            XCTAssertEqual(vm.stateFilter, "All")
            XCTAssertNil(vm.kindFilter)
            vm.loadIfNeeded()
            await vm.waitForCurrentLoad()
            vm.selectedAlarm = vm.alarms.first
            await vm.waitForDetails()
            vm.searchText = "cpu"
            vm.stateFilter = "ALARM"
            vm.kindFilter = .metric
        }
        let calls = await probe.counts()
        XCTAssertEqual(calls, [scopes.count, scopes.count, scopes.count])
        vm.configure(scope: scopes.last)
        vm.loadIfNeeded()
        let sameScopeCalls = await probe.counts()
        XCTAssertEqual(calls, sameScopeCalls)
        XCTAssertNotNil(vm.selectedAlarm)
    }

    func testOldScopeListSuccessOrFailureCannotReplaceNewList() async {
        for shouldFail in [false, true] {
            let gate = TestGate()
            let probe = AlarmProbe(listResults: [[makeAlarm("old")], [makeAlarm("new")]],
                                   firstListGate: gate, listFailures: shouldFail ? [1] : [])
            let vm = makeViewModel(probe)
            vm.configure(scope: alarmScope())
            vm.loadIfNeeded()
            await gate.waitForEntry()
            let waiting = Task { await vm.waitForCurrentLoad() }
            await Task.yield()
            vm.configure(scope: alarmScope(region: "eu-west-1"))
            vm.loadIfNeeded()
            await vm.waitForCurrentLoad()
            await gate.open()
            await waiting.value
            XCTAssertEqual(vm.alarms.map(\.name), ["new"])
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
        }
    }

    func testOldSelectionTagsAndHistorySuccessOrFailureCannotPublish() async {
        for shouldFail in [false, true] {
            let tagsGate = TestGate()
            let historyGate = TestGate()
            let probe = AlarmProbe(firstTagsGate: tagsGate, firstHistoryGate: historyGate,
                                   tagFailures: shouldFail ? [1] : [], historyFailures: shouldFail ? [1] : [])
            let vm = makeViewModel(probe)
            vm.configure(scope: alarmScope())
            await vm.loadAlarms()
            vm.selectedAlarm = vm.alarms[0]
            await tagsGate.waitForEntry()
            await historyGate.waitForEntry()
            let waiting = Task { await vm.waitForDetails() }
            await Task.yield()
            vm.selectedAlarm = vm.alarms[1]
            await vm.waitForDetails()
            await tagsGate.open()
            await historyGate.open()
            await waiting.value

            XCTAssertEqual(vm.selectedAlarm?.name, "composite")
            XCTAssertEqual(vm.tags["Name"], "composite")
            XCTAssertEqual(vm.history.first?.summary, "composite")
            XCTAssertNil(vm.tagsError)
            XCTAssertNil(vm.historyError)
            XCTAssertFalse(vm.isTagsLoading)
            XCTAssertFalse(vm.isHistoryLoading)
        }
    }

    func testResetInvalidatesPendingTagsAndHistoryAndAllSelectionState() async {
        let tagsGate = TestGate()
        let historyGate = TestGate()
        let probe = AlarmProbe(firstTagsGate: tagsGate, firstHistoryGate: historyGate)
        let vm = makeViewModel(probe)
        vm.configure(scope: alarmScope())
        await vm.loadAlarms()
        vm.selectedAlarm = vm.alarms[0]
        await tagsGate.waitForEntry()
        await historyGate.waitForEntry()
        let waiting = Task { await vm.waitForDetails() }
        await Task.yield()
        vm.reset()
        await tagsGate.open()
        await historyGate.open()
        await waiting.value
        XCTAssertNil(vm.scope)
        XCTAssertNil(vm.selectedAlarm)
        XCTAssertTrue(vm.alarms.isEmpty)
        XCTAssertTrue(vm.tags.isEmpty)
        XCTAssertTrue(vm.history.isEmpty)
        XCTAssertNil(vm.tagsError)
        XCTAssertNil(vm.historyError)
        XCTAssertFalse(vm.isTagsLoading)
        XCTAssertFalse(vm.isHistoryLoading)
    }

    func testTagsAndHistoryFailuresAreIndependentAndDetailsCanRetry() async {
        let probe = AlarmProbe(tagFailures: [1], historyFailures: [2])
        let vm = makeViewModel(probe)
        vm.configure(scope: alarmScope())
        await vm.loadAlarms()
        vm.selectedAlarm = vm.alarms[0]
        await vm.waitForDetails()
        XCTAssertNotNil(vm.tagsError)
        XCTAssertNil(vm.historyError)
        XCTAssertEqual(vm.history.count, 1)
        XCTAssertNotNil(vm.selectedAlarm)

        vm.refreshDetails()
        await vm.waitForDetails()
        XCTAssertNil(vm.tagsError)
        XCTAssertEqual(vm.tags["Name"], "cpu")
        XCTAssertNotNil(vm.historyError)
        XCTAssertTrue(vm.history.isEmpty)
        XCTAssertNotNil(vm.selectedAlarm)
    }

    func testListRefreshPreservesMatchingSelectionReloadsDetailsAndClearsDeletedSelection() async {
        let original = makeAlarm("cpu")
        let updated = makeAlarm("cpu", state: "OK")
        let probe = AlarmProbe(listResults: [[original], [updated], []])
        let vm = makeViewModel(probe)
        vm.configure(scope: alarmScope())
        await vm.loadAlarms()
        vm.selectedAlarm = vm.alarms.first
        await vm.waitForDetails()
        vm.refresh()
        await vm.waitForCurrentLoad()
        await vm.waitForDetails()
        XCTAssertEqual(vm.selectedAlarm, updated)
        let selectedCalls = await probe.counts()
        XCTAssertEqual(selectedCalls, [2, 2, 2])

        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertNil(vm.selectedAlarm)
        XCTAssertTrue(vm.tags.isEmpty)
        XCTAssertTrue(vm.history.isEmpty)
        let deletedCalls = await probe.counts()
        XCTAssertEqual(deletedCalls, [3, 2, 2])
    }

    func testFailedRefreshRetainsPriorCompleteListAndLabelsError() async {
        let probe = AlarmProbe(listFailures: [2])
        let vm = makeViewModel(probe)
        vm.configure(scope: alarmScope())
        await vm.loadAlarms()
        let previous = vm.alarms
        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.alarms, previous)
        XCTAssertNotNil(vm.error)
        XCTAssertNil(vm.selectedAlarm)
    }

    func testClearingSelectionImmediatelyClearsEnrichment() async {
        let probe = AlarmProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: alarmScope())
        await vm.loadAlarms()
        vm.selectedAlarm = vm.alarms[0]
        await vm.waitForDetails()
        vm.selectedAlarm = nil
        XCTAssertTrue(vm.tags.isEmpty)
        XCTAssertTrue(vm.history.isEmpty)
        XCTAssertNil(vm.tagsError)
        XCTAssertNil(vm.historyError)
        vm.refreshDetails()
        let calls = await probe.counts()
        XCTAssertEqual(calls, [1, 1, 1])
    }

    func testLocalFiltersSearchNameARNStateMetricMathDimensionsAndCompositeRuleWithoutRequests() async {
        let metric = CloudWatchAlarm(
            arn: "arn:aws:cloudwatch:us-east-1:111122223333:alarm:cpu", name: "cpu", kind: .metric, state: "ALARM",
            metrics: [.init(id: "m1", expression: "AVG(METRICS())", namespace: "AWS/EC2", metricName: "CPUUtilization",
                            dimensions: [.init(label: "InstanceId", value: "i-example")])]
        )
        let composite = CloudWatchAlarm(arn: "arn:aws:cloudwatch:us-east-1:111122223333:alarm:composite",
                                       name: "composite", kind: .composite, state: "OK", rule: "ALARM(cpu) AND OK(availability)")
        let probe = AlarmProbe(listResults: [[metric, composite]])
        let vm = makeViewModel(probe)
        vm.configure(scope: alarmScope())
        await vm.loadAlarms()
        for query in [" CPUUtilization ", "aws/ec2", "avg(metrics", "i-example", "InstanceId", ":alarm:cpu"] {
            vm.searchText = query
            XCTAssertEqual(vm.filteredAlarms, [metric], query)
        }
        vm.searchText = "cpu"
        XCTAssertEqual(vm.filteredAlarms, [metric, composite], "Composite rules also participate in local search")
        vm.searchText = "availability"
        XCTAssertEqual(vm.filteredAlarms, [composite])
        vm.searchText = ""
        vm.kindFilter = .composite
        XCTAssertEqual(vm.filteredAlarms, [composite])
        vm.stateFilter = "ALARM"
        XCTAssertTrue(vm.filteredAlarms.isEmpty)
        vm.kindFilter = nil
        XCTAssertEqual(vm.filteredAlarms, [metric])
        let calls = await probe.counts()
        XCTAssertEqual(calls, [1, 0, 0])
    }

    private func makeViewModel(_ probe: AlarmProbe) -> AlarmViewModel {
        AlarmViewModel(listLoader: { try await probe.list($0) },
                       tagLoader: { try await probe.tags($0, $1) },
                       historyLoader: { try await probe.history($0, $1) })
    }
}

private func alarmScope(
    profile: String = "work", account: String = "111122223333", role: String = "ReadOnly", region: String = "us-east-1",
    paths: AWSConfigurationPaths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/alarm-config"])
) -> AlarmScope {
    AlarmScope(
        profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
        identity: AWSIdentity(account: account, arn: "arn:aws:sts::\(account):assumed-role/\(role)/test", userID: "test"),
        region: region, paths: paths
    )
}

private func makeAlarm(_ name: String, state: String = "ALARM", kind: AlarmKind = .metric) -> CloudWatchAlarm {
    CloudWatchAlarm(arn: "arn:aws:cloudwatch:us-east-1:111122223333:alarm:\(name)", name: name, kind: kind, state: state)
}

private actor AlarmProbe {
    private var listCalls: [AlarmScope] = []
    private var tagCalls: [(AlarmScope, CloudWatchAlarm)] = []
    private var historyCalls: [(AlarmScope, CloudWatchAlarm)] = []
    private let listResults: [[CloudWatchAlarm]]
    private let firstListGate: TestGate?
    private let firstTagsGate: TestGate?
    private let firstHistoryGate: TestGate?
    private let listFailures: Set<Int>
    private let tagFailures: Set<Int>
    private let historyFailures: Set<Int>

    init(
        listResults: [[CloudWatchAlarm]] = [[makeAlarm("cpu"), makeAlarm("composite", state: "OK", kind: .composite)]],
        firstListGate: TestGate? = nil, firstTagsGate: TestGate? = nil, firstHistoryGate: TestGate? = nil,
        listFailures: Set<Int> = [], tagFailures: Set<Int> = [], historyFailures: Set<Int> = []
    ) {
        self.listResults = listResults
        self.firstListGate = firstListGate
        self.firstTagsGate = firstTagsGate
        self.firstHistoryGate = firstHistoryGate
        self.listFailures = listFailures
        self.tagFailures = tagFailures
        self.historyFailures = historyFailures
    }

    func counts() -> [Int] { [listCalls.count, tagCalls.count, historyCalls.count] }

    func list(_ scope: AlarmScope) async throws -> [CloudWatchAlarm] {
        listCalls.append(scope)
        let call = listCalls.count
        if call == 1 { await firstListGate?.wait() }
        if listFailures.contains(call) { throw AlarmError.invalidResponse }
        return listResults[min(call - 1, listResults.count - 1)]
    }

    func tags(_ scope: AlarmScope, _ alarm: CloudWatchAlarm) async throws -> [String: String] {
        tagCalls.append((scope, alarm))
        let call = tagCalls.count
        if call == 1 { await firstTagsGate?.wait() }
        if tagFailures.contains(call) { throw AlarmError.invalidResponse }
        return ["Name": alarm.name]
    }

    func history(_ scope: AlarmScope, _ alarm: CloudWatchAlarm) async throws -> [AlarmHistoryEntry] {
        historyCalls.append((scope, alarm))
        let call = historyCalls.count
        if call == 1 { await firstHistoryGate?.wait() }
        if historyFailures.contains(call) { throw AlarmError.invalidResponse }
        return [.init(id: "\(alarm.arn)-history", type: "StateUpdate", summary: alarm.name)]
    }
}
