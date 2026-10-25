import Foundation
import SotoCore
import SotoCloudWatch
import XCTest
@testable import AWSPlatform

final class ResourceMetricsServiceTests: XCTestCase {
    func testResourceTargetsAcceptOnlyExactInstanceIDsAndFunctionNames() {
        for target in [ResourceMetricTarget.ec2("i-12345678"), .ec2("i-0123456789abcdef0"),
                       .lambda("worker_1-v2"), .lambda(String(repeating: "a", count: 64))] {
            XCTAssertTrue(target.isValid)
        }
        for target in [ResourceMetricTarget.ec2("i-example"), .ec2("i-123456789"), .ec2("i-ABCDEF12"),
                       .ec2("i-12345678\n"), .lambda("worker\n"), .lambda(" worker"), .lambda("worker\t"),
                       .lambda("worker\u{0000}"), .lambda("worker:prod"), .lambda(""),
                       .lambda("arn:aws:lambda:us-east-1:111122223333:function:worker"),
                       .lambda(String(repeating: "a", count: 65))] {
            XCTAssertFalse(target.isValid, target.resourceID.debugDescription)
        }
    }

    func testEC2QueriesUseCurrentAccountInstanceAndFiveMinuteStatistics() async throws {
        let stub = MetricsPageStub(pages: [MetricsFixture.completePage()])
        let snapshot = try await service(stub).load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
        let requests = await stub.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(requests.count, 1)
        try assertRequest(request, target: MetricsFixture.ec2, namespace: "AWS/EC2", dimension: "InstanceId",
                          names: ["CPUUtilization", "NetworkIn", "NetworkOut", "StatusCheckFailed"],
                          stats: ["Average", "Sum", "Sum", "Maximum"])
        XCTAssertEqual(snapshot.series.map(\.id), ["cpu", "network_in", "network_out", "status_failed"])
        XCTAssertEqual(snapshot.series.map(\.unit), ["Percent", "Bytes", "Bytes", "Count"])
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertTrue(snapshot.series.allSatisfy { $0.points.isEmpty && $0.message?.contains("not treated as zero") == true })
        XCTAssertEqual(snapshot.start, MetricsFixture.end.addingTimeInterval(-3_600))
        XCTAssertEqual(snapshot.end, MetricsFixture.end)
        XCTAssertEqual(snapshot.fetchedAt, MetricsFixture.now)
    }

    func testLambdaQueriesUseFunctionNameAggregationAndRequestedRange() async throws {
        let stub = MetricsPageStub(pages: [MetricsFixture.completePage(lambda: true)])
        let snapshot = try await service(stub).load(scope: MetricsFixture.scope(), target: .lambda("worker"), range: .day)
        let requests = await stub.requests()
        let request = try XCTUnwrap(requests.first)
        try assertRequest(request, target: .lambda("worker"), namespace: "AWS/Lambda", dimension: "FunctionName",
                          names: ["Invocations", "Errors", "Throttles", "Duration"],
                          stats: ["Sum", "Sum", "Sum", "Average"], range: .day)
        XCTAssertEqual(snapshot.series.map(\.unit), ["Count", "Count", "Count", "Milliseconds"])
        XCTAssertEqual(snapshot.range, .day)
        XCTAssertTrue(snapshot.isComplete)
    }

    func testPaginationFreezesWindowAndMergesSortedPointsWithoutFillingGaps() async throws {
        let early = MetricsFixture.end.addingTimeInterval(-1_500)
        let middle = MetricsFixture.end.addingTimeInterval(-900)
        let late = MetricsFixture.end.addingTimeInterval(-300)
        let stub = MetricsPageStub(pages: [
            .init(metricDataResults: [
                .init(id: "cpu", statusCode: .partialData, timestamps: [late, early], values: [3, 1]),
                .init(id: "network_in", statusCode: .complete),
                .init(id: "network_out", statusCode: .complete),
                .init(id: "status_failed", statusCode: .complete)
            ], nextToken: "page-2"),
            .init(metricDataResults: [
                .init(id: "cpu", statusCode: .complete, timestamps: [middle, early], values: [2, 1])
            ])
        ])
        let snapshot = try await service(stub).load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .sixHours)
        XCTAssertEqual(snapshot.series[0].points.map(\.timestamp), [early, middle, late])
        XCTAssertEqual(snapshot.series[0].points.map(\.value), [1, 2, 3])
        XCTAssertTrue(snapshot.isComplete)
        let requests = await stub.requests()
        XCTAssertEqual(requests.map(\.nextToken), [nil, "page-2"])
        XCTAssertTrue(requests.allSatisfy { $0.startTime == snapshot.start && $0.endTime == snapshot.end })
        XCTAssertTrue(requests.allSatisfy { $0.metricDataQueries?.count == 4 })
    }

    func testIncompleteAndForbiddenResultsAreVisibleAndNeverComplete() async throws {
        let stub = MetricsPageStub(pages: [.init(metricDataResults: [
            .init(id: "cpu", statusCode: .partialData),
            .init(id: "network_in", label: "private-label", messages: [.init(value: "private-payload")], statusCode: .forbidden),
            .init(id: "network_out", statusCode: .internalError)
        ])])
        let snapshot = try await service(stub).load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
        XCTAssertEqual(snapshot.series.map(\.status), [.partial, .forbidden, .failed, .missing])
        XCTAssertFalse(snapshot.isComplete)
        XCTAssertTrue(snapshot.series.allSatisfy { $0.message != nil })
        XCTAssertFalse(snapshot.series.map { $0.message ?? "" }.joined().contains("private"))
        XCTAssertFalse(snapshot.series.map(\.title).joined().contains("private"))
    }

    func testFinalPartialPageCannotBeHiddenByEarlierCompleteStatus() async throws {
        let stub = MetricsPageStub(pages: [
            .init(metricDataResults: MetricsFixture.completePage().metricDataResults, nextToken: "page-2"),
            .init(metricDataResults: [.init(id: "cpu", statusCode: .partialData)])
        ])
        let snapshot = try await service(stub).load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
        XCTAssertEqual(snapshot.series[0].status, .partial)
        XCTAssertFalse(snapshot.isComplete)
    }

    func testWarningsAndUnknownStatusStayPartialEvenWhenLaterPageSaysComplete() async throws {
        let stub = MetricsPageStub(pages: [
            .init(metricDataResults: [
                .init(id: "cpu"),
                .init(id: "network_in", messages: [.init(code: "private-code", value: "private-message")], statusCode: .complete),
                .init(id: "network_out", statusCode: .forbidden),
                .init(id: "status_failed", statusCode: .internalError)
            ], nextToken: "page-2"),
            MetricsFixture.completePage()
        ])
        let snapshot = try await service(stub).load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
        XCTAssertEqual(snapshot.series.map(\.status), [.partial, .partial, .forbidden, .failed])
        XCTAssertFalse(snapshot.isComplete)

        let global = MetricsPageStub(pages: [
            .init(messages: [.init(value: "private-global")], metricDataResults: MetricsFixture.completePage().metricDataResults)
        ])
        let warned = try await service(global).load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
        XCTAssertTrue(warned.series.allSatisfy { $0.status == .partial })
        XCTAssertFalse(warned.series.map { $0.message ?? "" }.joined().contains("private-global"))
    }

    func testEmptyResponseIsMissingRatherThanZeroOrComplete() async throws {
        let stub = MetricsPageStub(pages: [.init()])
        let snapshot = try await service(stub).load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
        XCTAssertEqual(snapshot.series.count, 4)
        XCTAssertTrue(snapshot.series.allSatisfy { $0.status == .missing && $0.points.isEmpty })
        XCTAssertFalse(snapshot.isComplete)
    }

    func testMalformedIDsArraysValuesAndTimestampsRejectEntireResponse() async {
        let timestamp = MetricsFixture.end.addingTimeInterval(-300)
        let invalidRows: [[CloudWatch.MetricDataResult]] = [
            [.init(statusCode: .complete)],
            [.init(id: "other", statusCode: .complete)],
            [.init(id: "cpu", statusCode: .complete), .init(id: "cpu", statusCode: .complete)],
            [.init(id: "cpu", statusCode: .complete, timestamps: [timestamp], values: [])],
            [.init(id: "cpu", statusCode: .complete, values: [1])],
            [.init(id: "cpu", statusCode: .complete, timestamps: [timestamp], values: [.nan])],
            [.init(id: "cpu", statusCode: .complete, timestamps: [timestamp], values: [.infinity])],
            [.init(id: "cpu", statusCode: .complete, timestamps: [MetricsFixture.end], values: [1])],
            [.init(id: "cpu", statusCode: .complete, timestamps: [MetricsFixture.end.addingTimeInterval(-3_601)], values: [1])],
            [.init(id: "cpu", statusCode: .complete, timestamps: [Date(timeIntervalSince1970: .nan)], values: [1])],
            [.init(id: "cpu", statusCode: .complete, timestamps: [timestamp, timestamp], values: [1, 2])]
        ]
        for rows in invalidRows {
            let stub = MetricsPageStub(pages: [.init(metricDataResults: rows)])
            await assertMetricsError(.invalidResponse) {
                _ = try await self.service(stub).load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
            }
        }
    }

    func testConflictingDuplicateAcrossPagesRejectsSnapshot() async {
        let timestamp = MetricsFixture.end.addingTimeInterval(-300)
        let stub = MetricsPageStub(pages: [
            .init(metricDataResults: [.init(id: "cpu", statusCode: .partialData, timestamps: [timestamp], values: [1])], nextToken: "next"),
            .init(metricDataResults: [.init(id: "cpu", statusCode: .complete, timestamps: [timestamp], values: [2])])
        ])
        await assertMetricsError(.invalidResponse) {
            _ = try await self.service(stub).load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
        }
    }

    func testPaginationCycleAndPageLimitFailExplicitly() async {
        let cycle = MetricsPageStub(pages: [.init(nextToken: "again"), .init(nextToken: "again")])
        await assertMetricsError(.incompletePagination) {
            _ = try await self.service(cycle).load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
        }
        let cycleRequests = await cycle.requests()
        XCTAssertEqual(cycleRequests.count, 2)
        let bounded = MetricsPageStub(pages: (1...100).map { .init(nextToken: "page-\($0)") })
        await assertMetricsError(.incompletePagination) {
            _ = try await self.service(bounded).load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
        }
        let boundedRequests = await bounded.requests()
        XCTAssertEqual(boundedRequests.count, 100)
    }

    func testInvalidScopeTargetAndClockNeverCallTransport() async {
        let stub = MetricsPageStub(pages: [])
        for scope in [MetricsFixture.scope(account: ""), MetricsFixture.scope(region: "not-a-region"),
                      MetricsFixture.scope(profile: "")] {
            await assertMetricsError(.invalidContext) {
                _ = try await self.service(stub).load(scope: scope, target: MetricsFixture.ec2, range: .hour)
            }
        }
        await assertMetricsError(.invalidContext) {
            _ = try await self.service(stub).load(scope: MetricsFixture.scope(), target: .lambda("worker\n"), range: .hour)
        }
        let invalidClock = AWSMetricsService(pageLoader: { try await stub.load($0) }, now: { Date(timeIntervalSince1970: .infinity) })
        await assertMetricsError(.invalidContext) {
            _ = try await invalidClock.load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
        }
        let requests = await stub.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationAfterAwaitStopsPaginationAndDiscardsReturnedData() async {
        let gate = TestGate()
        let stub = MetricsPageStub(pages: [.init(nextToken: "next"), MetricsFixture.completePage()], gate: gate)
        let metrics = service(stub)
        let task = Task {
            try await metrics.load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
        }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("Cancelled request must not return a snapshot")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let requests = await stub.requests()
        XCTAssertEqual(requests.count, 1)
    }

    func testServiceFailuresAreSanitizedAndProviderScopeErrorIsRecognized() async {
        let failures: [(Error, AWSMetricsService.RequestError)] = [
            (AWSResponseError(errorCode: "AccessDeniedException"), .permission),
            (AWSResponseError(errorCode: "ExpiredToken"), .credentials),
            (AWSResponseError(errorCode: "ThrottlingException"), .throttled),
            (URLError(.timedOut), .network),
            (MetricsPrivateError(), .failed)
        ]
        for (failure, expected) in failures {
            let stub = MetricsPageStub(pages: [], failure: failure)
            do {
                _ = try await service(stub).load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
                XCTFail("Expected sanitized failure")
            } catch {
                XCTAssertEqual(error as? AWSMetricsService.RequestError, expected)
                XCTAssertFalse(error.localizedDescription.contains("private"))
            }
        }
        for failure in [AlarmError.invalidScope as Error, ResourceMetricsError.invalidContext] {
            let stub = MetricsPageStub(pages: [], failure: failure)
            await assertMetricsError(.invalidContext) {
                _ = try await self.service(stub).load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
            }
        }
        let invalidToken = MetricsPageStub(pages: [], failure: AWSResponseError(errorCode: "InvalidNextToken"))
        await assertMetricsError(.incompletePagination) {
            _ = try await self.service(invalidToken).load(scope: MetricsFixture.scope(), target: MetricsFixture.ec2, range: .hour)
        }
    }

    private func service(_ stub: MetricsPageStub) -> AWSMetricsService {
        AWSMetricsService(pageLoader: { try await stub.load($0) }, now: { MetricsFixture.now })
    }

    private func assertRequest(
        _ request: CloudWatch.GetMetricDataInput, target: ResourceMetricTarget, namespace: String,
        dimension: String, names: [String], stats: [String], range: MonitoringTimeRange = .hour
    ) throws {
        let queries = try XCTUnwrap(request.metricDataQueries)
        XCTAssertEqual(queries.count, 4)
        XCTAssertEqual(request.scanBy, .timestampAscending)
        XCTAssertEqual(request.maxDatapoints, 100_800)
        XCTAssertEqual(request.startTime, MetricsFixture.end.addingTimeInterval(-range.duration))
        XCTAssertEqual(request.endTime, MetricsFixture.end)
        for (index, query) in queries.enumerated() {
            let stat = try XCTUnwrap(query.metricStat)
            let metric = try XCTUnwrap(stat.metric)
            XCTAssertEqual(query.accountId, "111122223333")
            XCTAssertEqual(query.returnData, true)
            XCTAssertNil(query.expression)
            XCTAssertEqual(stat.period, 300)
            XCTAssertEqual(stat.stat, stats[index])
            XCTAssertNil(stat.unit)
            XCTAssertEqual(metric.namespace, namespace)
            XCTAssertEqual(metric.metricName, names[index])
            XCTAssertEqual(metric.dimensions?.count, 1)
            XCTAssertEqual(metric.dimensions?.first?.name, dimension)
            XCTAssertEqual(metric.dimensions?.first?.value, target.resourceID)
        }
    }

    private func assertMetricsError(
        _ expected: ResourceMetricsError, operation: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected metrics error", file: file, line: line)
        } catch let error as ResourceMetricsError {
            XCTAssertEqual(error.localizedDescription, expected.localizedDescription, file: file, line: line)
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))", file: file, line: line)
        }
    }
}

@MainActor
final class ResourceMetricsViewModelTests: XCTestCase {
    func testValidConfigurationDoesNotQueryUntilExplicitRefresh() async {
        let probe = MetricsLoadProbe()
        let vm = makeVM(probe)
        vm.refresh()
        vm.configure(scope: nil, target: MetricsFixture.ec2)
        vm.refresh()
        vm.configure(scope: MetricsFixture.scope(profile: ""), target: MetricsFixture.ec2)
        vm.refresh()
        vm.configure(scope: MetricsFixture.scope(), target: .lambda("worker\n"))
        vm.refresh()
        var calls = await probe.calls()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertNil(vm.scope)

        vm.configure(scope: MetricsFixture.scope(), target: MetricsFixture.ec2)
        calls = await probe.calls()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertNil(vm.snapshot)
        vm.refresh()
        await vm.waitForCurrentLoad()
        XCTAssertNotNil(vm.snapshot)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.error)
        vm.configure(scope: MetricsFixture.scope(), target: MetricsFixture.ec2)
        XCTAssertNotNil(vm.snapshot)
        calls = await probe.calls()
        XCTAssertEqual(calls.count, 1)
    }

    func testRefreshWhileLoadingIsDeduplicatedAndExplicitLaterRefreshWorks() async {
        let gate = TestGate()
        let probe = MetricsLoadProbe(firstGate: gate)
        let vm = makeVM(probe)
        vm.configure(scope: MetricsFixture.scope(), target: MetricsFixture.ec2)
        vm.refresh()
        await gate.waitForEntry()
        vm.refresh()
        let during = await probe.calls()
        XCTAssertEqual(during.count, 1)
        await gate.open()
        await vm.waitForCurrentLoad()
        vm.refresh()
        await vm.waitForCurrentLoad()
        let after = await probe.calls()
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(vm.snapshot?.series.first?.points.first?.value, 2)
    }

    func testRangeChangeClearsWithoutAutomaticQueryAndDropsOldResponse() async {
        let gate = TestGate()
        let probe = MetricsLoadProbe(firstGate: gate)
        let vm = makeVM(probe)
        vm.configure(scope: MetricsFixture.scope(), target: MetricsFixture.ec2)
        vm.refresh()
        await gate.waitForEntry()
        let oldWaiter = Task { await vm.waitForCurrentLoad() }
        await Task.yield()
        vm.timeRange = .sixHours
        XCTAssertNil(vm.snapshot)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.error)
        var calls = await probe.calls()
        XCTAssertEqual(calls.count, 1)
        vm.refresh()
        await vm.waitForCurrentLoad()
        await gate.open()
        await oldWaiter.value
        XCTAssertEqual(vm.snapshot?.range, .sixHours)
        XCTAssertEqual(vm.snapshot?.series.first?.points.first?.value, 2)
        calls = await probe.calls()
        XCTAssertEqual(calls.map(\.range), [.hour, .sixHours])
    }

    func testFullScopeChangesClearDataWithoutLoadingAndResetRange() async {
        let probe = MetricsLoadProbe()
        let vm = makeVM(probe)
        let scopes = [
            MetricsFixture.scope(),
            MetricsFixture.scope(profile: "second"),
            MetricsFixture.scope(account: "444455556666"),
            MetricsFixture.scope(principal: "arn:aws:sts::111122223333:assumed-role/Other/session"),
            MetricsFixture.scope(region: "eu-west-1"),
            MetricsFixture.scope(config: "/tmp/other-config"),
            MetricsFixture.scope(credentials: "/tmp/other-credentials")
        ]
        for (index, scope) in scopes.enumerated() {
            vm.configure(scope: scope, target: MetricsFixture.ec2)
            XCTAssertNil(vm.snapshot)
            XCTAssertNil(vm.error)
            XCTAssertEqual(vm.timeRange, .hour)
            let before = await probe.calls()
            XCTAssertEqual(before.count, index)
            vm.timeRange = .day
            vm.refresh()
            await vm.waitForCurrentLoad()
            XCTAssertNotNil(vm.snapshot)
        }
        vm.configure(scope: scopes.last, target: .lambda("worker"))
        XCTAssertNil(vm.snapshot)
        XCTAssertEqual(vm.timeRange, .hour)
        XCTAssertEqual(vm.target, .lambda("worker"))
    }

    func testContextChangeRejectsLateSuccessAndFailureFromPreviousResource() async {
        for shouldFail in [false, true] {
            let gate = TestGate()
            let probe = MetricsLoadProbe(firstGate: gate, failFirst: shouldFail)
            let vm = makeVM(probe)
            vm.configure(scope: MetricsFixture.scope(), target: MetricsFixture.ec2)
            vm.refresh()
            await gate.waitForEntry()
            let oldWaiter = Task { await vm.waitForCurrentLoad() }
            await Task.yield()
            vm.configure(scope: MetricsFixture.scope(profile: "second"), target: .lambda("new-function"))
            vm.refresh()
            await vm.waitForCurrentLoad()
            await gate.open()
            await oldWaiter.value
            XCTAssertEqual(vm.snapshot?.target, .lambda("new-function"))
            XCTAssertEqual(vm.snapshot?.series.first?.points.first?.value, 2)
            XCTAssertEqual(vm.scope?.profile.name, "second")
            XCTAssertFalse(vm.isLoading)
            XCTAssertNil(vm.error)
        }
    }

    func testResetAndNilConfigurationPreventLateRepopulation() async {
        for useReset in [true, false] {
            let gate = TestGate()
            let probe = MetricsLoadProbe(firstGate: gate)
            let vm = makeVM(probe)
            vm.configure(scope: MetricsFixture.scope(), target: MetricsFixture.ec2)
            vm.timeRange = .day
            vm.refresh()
            await gate.waitForEntry()
            let oldWaiter = Task { await vm.waitForCurrentLoad() }
            await Task.yield()
            if useReset { vm.reset() } else { vm.configure(scope: nil, target: nil) }
            await gate.open()
            await oldWaiter.value
            XCTAssertNil(vm.snapshot)
            XCTAssertNil(vm.scope)
            XCTAssertNil(vm.target)
            XCTAssertFalse(vm.isLoading)
            XCTAssertNil(vm.error)
            XCTAssertEqual(vm.timeRange, .hour)
        }
    }

    func testCancelPreservesContextAllowsManualRetryAndIgnoresLateResponse() async {
        let gate = TestGate()
        let probe = MetricsLoadProbe(firstGate: gate)
        let vm = makeVM(probe)
        vm.configure(scope: MetricsFixture.scope(), target: MetricsFixture.ec2)
        vm.timeRange = .sixHours
        vm.refresh()
        await gate.waitForEntry()
        let oldWaiter = Task { await vm.waitForCurrentLoad() }
        await Task.yield()
        vm.cancelLoading()
        XCTAssertEqual(vm.scope, MetricsFixture.scope())
        XCTAssertEqual(vm.target, MetricsFixture.ec2)
        XCTAssertEqual(vm.timeRange, .sixHours)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.snapshot)
        XCTAssertTrue(vm.error?.contains("cancelled") == true)
        vm.configure(scope: MetricsFixture.scope(), target: MetricsFixture.ec2)
        let beforeRetry = await probe.calls()
        XCTAssertEqual(beforeRetry.count, 1)
        vm.refresh()
        await vm.waitForCurrentLoad()
        await gate.open()
        await oldWaiter.value
        XCTAssertEqual(vm.snapshot?.series.first?.points.first?.value, 2)
        XCTAssertNil(vm.error)
        vm.cancelLoading()
        XCTAssertNotNil(vm.snapshot)
    }

    func testLoaderErrorsAreSanitizedAndMismatchedSnapshotsAreRejected() async {
        let failure = ResourceMetricsViewModel { _, _, _ in throw MetricsPrivateError() }
        failure.configure(scope: MetricsFixture.scope(), target: MetricsFixture.ec2)
        failure.refresh()
        await failure.waitForCurrentLoad()
        XCTAssertEqual(failure.error, AWSMetricsService.RequestError.failed.localizedDescription)
        XCTAssertFalse(failure.error?.contains("private") == true)
        XCTAssertNil(failure.snapshot)

        for invalid in [
            MetricsFixture.snapshot(target: .lambda("other"), range: .hour),
            MetricsFixture.snapshot(target: MetricsFixture.ec2, range: .day),
            ResourceMetricsSnapshot(target: MetricsFixture.ec2, range: .hour, start: MetricsFixture.end,
                                    end: MetricsFixture.end, series: [], fetchedAt: MetricsFixture.now),
            ResourceMetricsSnapshot(target: MetricsFixture.ec2, range: .hour,
                                    start: MetricsFixture.end.addingTimeInterval(-3_600), end: MetricsFixture.end,
                                    period: 60, series: [], fetchedAt: MetricsFixture.now)
        ] {
            let vm = ResourceMetricsViewModel { _, _, _ in invalid }
            vm.configure(scope: MetricsFixture.scope(), target: MetricsFixture.ec2)
            vm.refresh()
            await vm.waitForCurrentLoad()
            XCTAssertNil(vm.snapshot)
            XCTAssertFalse(vm.isLoading)
            XCTAssertEqual(vm.error, ResourceMetricsError.invalidResponse.localizedDescription)
        }
    }

    private func makeVM(_ probe: MetricsLoadProbe) -> ResourceMetricsViewModel {
        ResourceMetricsViewModel { try await probe.load(scope: $0, target: $1, range: $2) }
    }
}

private enum MetricsFixture {
    static let now = Date(timeIntervalSince1970: 1_780_000_123)
    static let end = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 300) * 300)
    static let ec2 = ResourceMetricTarget.ec2("i-0123456789abcdef0")

    static func scope(
        profile: String = "test", account: String = "111122223333", principal: String? = nil,
        region: String = "us-east-1", config: String = "/tmp/metrics-config",
        credentials: String = "/tmp/metrics-credentials"
    ) -> MonitoringScope {
        MonitoringScope(
            profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil,
                                ssoAccountID: nil, ssoRoleName: nil),
            identity: AWSIdentity(account: account, arn: principal ?? "arn:aws:sts::\(account):assumed-role/ReadOnly/session", userID: "test"),
            region: region,
            paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": config, "AWS_SHARED_CREDENTIALS_FILE": credentials])
        )
    }

    static func completePage(lambda: Bool = false) -> CloudWatch.GetMetricDataOutput {
        let ids = lambda ? ["invocations", "errors", "throttles", "duration"] : ["cpu", "network_in", "network_out", "status_failed"]
        return .init(metricDataResults: ids.map { .init(id: $0, statusCode: .complete) })
    }

    static func snapshot(target: ResourceMetricTarget, range: MonitoringTimeRange, value: Double = 1) -> ResourceMetricsSnapshot {
        .init(target: target, range: range, start: end.addingTimeInterval(-range.duration), end: end,
              series: [.init(id: "metric", title: "Metric", unit: "Count", statistic: "Sum",
                             points: [.init(timestamp: end.addingTimeInterval(-300), value: value)], status: .complete)],
              fetchedAt: now)
    }
}

private struct MetricsPrivateError: LocalizedError {
    var errorDescription: String? { "private-endpoint-and-request-data" }
}

private actor MetricsPageStub {
    private var pages: [CloudWatch.GetMetricDataOutput]
    private let failure: Error?
    private let gate: TestGate?
    private var recorded: [CloudWatch.GetMetricDataInput] = []

    init(pages: [CloudWatch.GetMetricDataOutput], failure: Error? = nil, gate: TestGate? = nil) {
        self.pages = pages
        self.failure = failure
        self.gate = gate
    }

    func load(_ request: CloudWatch.GetMetricDataInput) async throws -> CloudWatch.GetMetricDataOutput {
        recorded.append(request)
        if recorded.count == 1, let gate { await gate.wait() }
        if let failure { throw failure }
        guard !pages.isEmpty else { throw ResourceMetricsError.invalidResponse }
        return pages.removeFirst()
    }

    func requests() -> [CloudWatch.GetMetricDataInput] { recorded }
}

private actor MetricsLoadProbe {
    struct Call: Sendable {
        let scope: MonitoringScope
        let target: ResourceMetricTarget
        let range: MonitoringTimeRange
    }

    private let firstGate: TestGate?
    private let failFirst: Bool
    private var recorded: [Call] = []

    init(firstGate: TestGate? = nil, failFirst: Bool = false) {
        self.firstGate = firstGate
        self.failFirst = failFirst
    }

    func load(scope: MonitoringScope, target: ResourceMetricTarget, range: MonitoringTimeRange) async throws -> ResourceMetricsSnapshot {
        recorded.append(Call(scope: scope, target: target, range: range))
        let index = recorded.count
        if index == 1, let firstGate { await firstGate.wait() }
        if index == 1 && failFirst { throw MetricsPrivateError() }
        return MetricsFixture.snapshot(target: target, range: range, value: Double(index))
    }

    func calls() -> [Call] { recorded }
}
