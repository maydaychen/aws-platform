import XCTest
@testable import AWSPlatform

@MainActor
final class CostViewModelTests: XCTestCase {
    func testNoProfileAndConfigureNeverStartRequests() async {
        let probe = CostLoaderProbe()
        let vm = makeViewModel(probe)
        vm.loadIfNeeded()
        vm.refresh()
        vm.applyFilters()
        await vm.waitForCurrentLoad()
        vm.configure(scope: costScope())
        let calls = await probe.calls

        XCTAssertTrue(calls.isEmpty)
        XCTAssertNil(vm.report)
        XCTAssertFalse(vm.isLoading)
    }

    func testFirstVisitDeduplicatesPendingLoadAndReusesOnReentry() async {
        let gate = TestGate()
        let probe = CostLoaderProbe(gate: gate)
        let vm = makeViewModel(probe)
        vm.configure(scope: costScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        vm.loadIfNeeded()
        vm.applyFilters()
        XCTAssertTrue(vm.isLoading)
        await gate.open()
        await vm.waitForCurrentLoad()
        vm.loadIfNeeded()
        let calls = await probe.calls

        XCTAssertEqual(calls.count, 1)
        XCTAssertNotNil(vm.report)
        XCTAssertFalse(vm.isLoading)
    }

    func testDraftFiltersDoNotFetchOrRelabelSavedReportAndApplyUsesCache() async throws {
        let probe = CostLoaderProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: costScope())
        vm.loadIfNeeded()
        await vm.waitForCurrentLoad()
        let original = try XCTUnwrap(vm.report?.query)
        vm.period = .lastMonth
        vm.selectedRegion = "ap-southeast-1"
        XCTAssertTrue(vm.hasUnappliedFilters)
        XCTAssertEqual(vm.report?.query, original)
        var calls = await probe.calls
        XCTAssertEqual(calls.count, 1)

        vm.applyFilters()
        XCTAssertNil(vm.report, "A new query must not carry old totals under new labels")
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.report?.query.region, "ap-southeast-1")
        XCTAssertFalse(vm.hasUnappliedFilters)

        vm.period = .thisMonth
        vm.selectedRegion = nil
        vm.applyFilters()
        await vm.waitForCurrentLoad()
        calls = await probe.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(vm.report?.query, original)
    }

    func testRefreshUsesAppliedFiltersAndRetainsSavedDataWhenItFails() async throws {
        let probe = CostLoaderProbe(failingCalls: [2])
        let vm = makeViewModel(probe)
        vm.configure(scope: costScope())
        vm.loadIfNeeded()
        await vm.waitForCurrentLoad()
        let original = try XCTUnwrap(vm.report?.query)
        vm.period = .lastMonth
        vm.refresh()
        await vm.waitForCurrentLoad()
        vm.loadIfNeeded()
        let calls = await probe.calls

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.1, original)
        XCTAssertEqual(vm.report?.query, original)
        XCTAssertNotNil(vm.error)
        XCTAssertTrue(vm.hasUnappliedFilters)
    }

    func testFailedFirstVisitIsNotRetriedByReentryButApplyRetries() async {
        let probe = CostLoaderProbe(failingCalls: [1])
        let vm = makeViewModel(probe)
        vm.configure(scope: costScope())
        vm.loadIfNeeded()
        await vm.waitForCurrentLoad()
        XCTAssertNotNil(vm.error)
        XCTAssertNil(vm.report)
        vm.loadIfNeeded()
        await vm.waitForCurrentLoad()
        var calls = await probe.calls
        XCTAssertEqual(calls.count, 1)

        vm.applyFilters()
        await vm.waitForCurrentLoad()
        calls = await probe.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertNil(vm.error)
        XCTAssertNotNil(vm.report)
    }

    func testCancellationPreventsLateResultAndDoesNotAutoRetry() async {
        let gate = TestGate()
        let probe = CostLoaderProbe(gate: gate)
        let vm = makeViewModel(probe)
        vm.configure(scope: costScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        let waiting = Task { await vm.waitForCurrentLoad() }
        await Task.yield()
        vm.cancel()
        XCTAssertFalse(vm.isLoading)
        XCTAssertNotNil(vm.statusMessage)
        await gate.open()
        await waiting.value
        vm.loadIfNeeded()
        let firstCalls = await probe.calls
        XCTAssertEqual(firstCalls.count, 1)
        XCTAssertNil(vm.report)

        vm.refresh()
        await vm.waitForCurrentLoad()
        let finalCalls = await probe.calls
        XCTAssertEqual(finalCalls.count, 2)
        XCTAssertNotNil(vm.report)
        XCTAssertNil(vm.statusMessage)
    }

    func testOldProfileSuccessAndFailureCannotPublishOrCache() async {
        for shouldFail in [false, true] {
            let gate = TestGate()
            let probe = CostLoaderProbe(gate: gate, failingCalls: shouldFail ? [1] : [])
            let vm = makeViewModel(probe)
            let oldScope = costScope("old", account: "111122223333")
            let newScope = costScope("new", account: "444455556666")
            vm.configure(scope: oldScope)
            vm.loadIfNeeded()
            await gate.waitForEntry()
            let oldWaiting = Task { await vm.waitForCurrentLoad() }
            await Task.yield()
            vm.configure(scope: newScope)
            XCTAssertNil(vm.report)
            vm.loadIfNeeded()
            await vm.waitForCurrentLoad()
            await gate.open()
            await oldWaiting.value

            XCTAssertEqual(vm.scope, newScope)
            XCTAssertNotNil(vm.report)
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
            vm.configure(scope: oldScope)
            vm.loadIfNeeded()
            await vm.waitForCurrentLoad()
            let calls = await probe.calls
            XCTAssertEqual(calls.count, 3, "Old context results must not populate a reused profile's cache")
        }
    }

    func testResetClearsContextAndBlocksLateSuccess() async {
        let gate = TestGate()
        let probe = CostLoaderProbe(gate: gate)
        let vm = makeViewModel(probe)
        vm.configure(scope: costScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        let waiting = Task { await vm.waitForCurrentLoad() }
        await Task.yield()
        vm.reset()
        await gate.open()
        await waiting.value

        XCTAssertNil(vm.scope)
        XCTAssertNil(vm.appliedQuery)
        XCTAssertNil(vm.report)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isLoading)
        vm.loadIfNeeded()
        let calls = await probe.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testProfileIdentityAndConfigurationPathsAreCacheBoundaries() async {
        let probe = CostLoaderProbe()
        let vm = makeViewModel(probe)
        let scopes = [
            costScope(),
            costScope(role: "AnotherRole"),
            costScope(account: "444455556666"),
            costScope(paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/other-config", "AWS_SHARED_CREDENTIALS_FILE": "/tmp/other-credentials"]))
        ]
        for scope in scopes {
            vm.configure(scope: scope)
            XCTAssertNil(vm.report)
            vm.loadIfNeeded()
            await vm.waitForCurrentLoad()
        }
        let calls = await probe.calls
        XCTAssertEqual(calls.count, scopes.count)
        vm.configure(scope: scopes.last)
        vm.loadIfNeeded()
        let finalCalls = await probe.calls
        XCTAssertEqual(finalCalls.count, scopes.count, "The same verified scope must preserve its cache")
    }

    func testOldQueryCannotReplaceNewerAppliedQuery() async {
        let gate = TestGate()
        let probe = CostLoaderProbe(gate: gate)
        let vm = makeViewModel(probe)
        vm.configure(scope: costScope())
        vm.loadIfNeeded()
        await gate.waitForEntry()
        let waiting = Task { await vm.waitForCurrentLoad() }
        await Task.yield()
        vm.period = .lastMonth
        vm.applyFilters()
        await vm.waitForCurrentLoad()
        let latest = vm.report?.query
        await gate.open()
        await waiting.value

        XCTAssertEqual(vm.report?.query, latest)
        XCTAssertEqual(latest?.range, CostPeriod.lastMonth.range(now: costNow))
        XCTAssertFalse(vm.isLoading)
        vm.period = .thisMonth
        vm.applyFilters()
        await vm.waitForCurrentLoad()
        let calls = await probe.calls
        XCTAssertEqual(calls.count, 3, "A cancelled old query cannot be cached")
    }

    func testCacheEvictsLeastRecentlyUsedAfterEightQueries() async {
        let probe = CostLoaderProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: costScope())
        for index in 0..<8 {
            vm.selectedRegion = "region-\(index)"
            vm.applyFilters()
            await vm.waitForCurrentLoad()
        }
        vm.selectedRegion = "region-0"
        vm.applyFilters()
        vm.selectedRegion = "region-8"
        vm.applyFilters()
        await vm.waitForCurrentLoad()
        vm.selectedRegion = "region-0"
        vm.applyFilters()
        var calls = await probe.calls
        XCTAssertEqual(calls.count, 9, "Recently used entry remains cached")
        vm.selectedRegion = "region-1"
        vm.applyFilters()
        await vm.waitForCurrentLoad()
        calls = await probe.calls
        XCTAssertEqual(calls.count, 10)
    }

    func testInvalidCustomDatesDoNotSendRequestOrRelabelReport() async {
        let probe = CostLoaderProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: costScope())
        vm.loadIfNeeded()
        await vm.waitForCurrentLoad()
        let original = vm.report?.query
        vm.period = .custom
        vm.customStart = CostDates.date("2026-10-02")!
        vm.customEnd = CostDates.date("2026-10-01")!
        vm.applyFilters()
        XCTAssertNotNil(vm.error)
        XCTAssertEqual(vm.report?.query, original)

        vm.customStart = CostDates.date("2024-01-01")!
        vm.customEnd = CostDates.date("2024-01-02")!
        vm.applyFilters()
        XCTAssertNotNil(vm.error)
        vm.customStart = costNow
        vm.customEnd = costNow
        vm.applyFilters()
        XCTAssertNotNil(vm.error)
        let calls = await probe.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testCustomEndDateIsInclusiveWhileRequestEndIsExclusive() async {
        let probe = CostLoaderProbe()
        let vm = makeViewModel(probe)
        vm.configure(scope: costScope())
        vm.period = .custom
        vm.customStart = CostDates.date("2026-09-01")!
        vm.customEnd = CostDates.date("2026-09-03")!
        vm.applyFilters()
        await vm.waitForCurrentLoad()
        let calls = await probe.calls
        XCTAssertEqual(calls.first?.1.range.startString, "2026-09-01")
        XCTAssertEqual(calls.first?.1.range.endString, "2026-09-04")
    }

    func testMismatchedLoaderResultIsRejectedWithoutCaching() async {
        let probe = CostLoaderProbe(mismatchedQuery: true)
        let vm = makeViewModel(probe)
        vm.configure(scope: costScope())
        vm.loadIfNeeded()
        await vm.waitForCurrentLoad()
        XCTAssertNil(vm.report)
        XCTAssertNotNil(vm.error)
        vm.applyFilters()
        await vm.waitForCurrentLoad()
        let calls = await probe.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testMonthFirstKeepsDefaultEmptyWindowAndValidCustomPickerDates() async {
        let probe = CostLoaderProbe()
        let first = CostDates.date("2026-10-01")!
        let vm = CostViewModel(loader: { scope, query in try await probe.load(scope, query) }, now: { first })
        vm.configure(scope: costScope())
        XCTAssertTrue(vm.query.range.isEmpty)
        XCTAssertLessThanOrEqual(vm.customStart, vm.customEnd)
        XCTAssertLessThanOrEqual(vm.customStart, vm.latestDate)
    }

    func testRefreshAdvancesAppliedMonthAcrossUTCMonthWithoutApplyingDrafts() async {
        let probe = CostLoaderProbe()
        let clock = CostTestClock(CostDates.date("2026-09-30")!)
        let vm = CostViewModel(loader: { scope, query in try await probe.load(scope, query) }, now: { clock.date })
        vm.configure(scope: costScope())
        vm.loadIfNeeded()
        await vm.waitForCurrentLoad()
        let original = vm.report?.query
        vm.period = .lastMonth
        vm.selectedRegion = "draft-region"
        clock.date = CostDates.date("2026-10-02")!
        vm.loadIfNeeded()
        XCTAssertEqual(vm.report?.query, original, "Crossing midnight must not trigger an automatic paid request")
        vm.refresh()
        await vm.waitForCurrentLoad()

        XCTAssertEqual(vm.report?.query.range.startString, "2026-10-01")
        XCTAssertEqual(vm.report?.query.range.endString, "2026-10-02")
        XCTAssertEqual(vm.report?.query.summaryRange.startString, "2026-09-01")
        XCTAssertNil(vm.report?.query.region, "Refresh must not use an unapplied region")
        XCTAssertTrue(vm.hasUnappliedFilters)
        let calls = await probe.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testRefreshAdvancesAppliedLastThirtyDaysAcrossUTCDay() async {
        let probe = CostLoaderProbe()
        let clock = CostTestClock(CostDates.date("2026-10-03")!)
        let vm = CostViewModel(loader: { scope, query in try await probe.load(scope, query) }, now: { clock.date })
        vm.configure(scope: costScope())
        vm.period = .last30Days
        vm.applyFilters()
        await vm.waitForCurrentLoad()
        clock.date = CostDates.date("2026-10-04")!
        vm.refresh()
        await vm.waitForCurrentLoad()

        XCTAssertEqual(vm.report?.query.range.startString, "2026-09-04")
        XCTAssertEqual(vm.report?.query.range.endString, "2026-10-04")
        XCTAssertFalse(vm.hasUnappliedFilters)
    }

    func testCustomRefreshKeepsAppliedDatesAndRegionButAdvancesSummary() async {
        let probe = CostLoaderProbe()
        let clock = CostTestClock(CostDates.date("2026-09-30")!)
        let vm = CostViewModel(loader: { scope, query in try await probe.load(scope, query) }, now: { clock.date })
        vm.configure(scope: costScope())
        vm.period = .custom
        vm.customStart = CostDates.date("2026-08-01")!
        vm.customEnd = CostDates.date("2026-08-03")!
        vm.selectedRegion = "us-east-1"
        vm.applyFilters()
        await vm.waitForCurrentLoad()
        vm.customEnd = CostDates.date("2026-08-20")!
        vm.selectedRegion = "draft-region"
        clock.date = CostDates.date("2026-10-02")!
        vm.refresh()
        await vm.waitForCurrentLoad()

        XCTAssertEqual(vm.report?.query.range.startString, "2026-08-01")
        XCTAssertEqual(vm.report?.query.range.endString, "2026-08-04")
        XCTAssertEqual(vm.report?.query.region, "us-east-1")
        XCTAssertEqual(vm.report?.query.summaryRange.startString, "2026-09-01")
        XCTAssertEqual(vm.report?.query.summaryRange.endString, "2026-10-02")
        XCTAssertTrue(vm.hasUnappliedFilters)
    }

    private func makeViewModel(_ probe: CostLoaderProbe) -> CostViewModel {
        CostViewModel(loader: { scope, query in try await probe.load(scope, query) }, now: { costNow })
    }
}

private let costNow = CostDates.date("2026-10-03")!

@MainActor
private final class CostTestClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private func costScope(
    _ name: String = "work", account: String = "111122223333", role: String = "ReadOnly",
    paths: AWSConfigurationPaths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/cost-config", "AWS_SHARED_CREDENTIALS_FILE": "/tmp/cost-credentials"])
) -> CostScope {
    CostScope(
        profile: AWSProfile(name: name, region: "ap-southeast-1", ssoStartURL: nil, ssoRegion: nil,
                            ssoAccountID: nil, ssoRoleName: nil),
        identity: AWSIdentity(account: account, arn: "arn:aws:sts::\(account):assumed-role/\(role)/test", userID: "test"),
        paths: paths
    )
}

private actor CostLoaderProbe {
    private(set) var calls: [(CostScope, CostQuery)] = []
    private let gate: TestGate?
    private let failingCalls: Set<Int>
    private let mismatchedQuery: Bool

    init(gate: TestGate? = nil, failingCalls: Set<Int> = [], mismatchedQuery: Bool = false) {
        self.gate = gate
        self.failingCalls = failingCalls
        self.mismatchedQuery = mismatchedQuery
    }

    func load(_ scope: CostScope, _ query: CostQuery) async throws -> CostReport {
        calls.append((scope, query))
        let call = calls.count
        if call == 1 { await gate?.wait() }
        if failingCalls.contains(call) { throw CostError.invalidResponse }
        let responseQuery = mismatchedQuery
            ? CostQuery(range: query.range, region: "unexpected-region", referenceDate: query.referenceDate)
            : query
        return CostReport(
            query: responseQuery, currency: "USD", thisMonth: 25, lastMonth: 100,
            daily: [CostDailyAmount(date: "2026-10-01", amount: 25)],
            services: [CostServiceAmount(name: "Amazon EC2", amount: 25)],
            regions: ["us-east-1", "ap-southeast-1"], estimated: true,
            fetchedAt: costNow, apiRequestCount: 3
        )
    }
}
