import Foundation
import SotoCore
import SotoCloudWatchLogs
import XCTest
@testable import AWSPlatform

final class LambdaLogsTests: XCTestCase {
    func testContextDefaultsOnlyAbsentConfigurationAndMatchesExactFunctionStreams() {
        let context = LambdaLogContext(functionName: "handler", configuredLogGroup: nil)
        XCTAssertEqual(context.logGroup, "/aws/lambda/handler")
        XCTAssertFalse(context.isCustomGroup)
        XCTAssertFalse(LambdaLogContext(functionName: "handler", configuredLogGroup: "").isValid)
        XCTAssertFalse(LambdaLogContext(functionName: "handler\n", configuredLogGroup: nil).isValid)
        XCTAssertFalse(LambdaLogContext(functionName: "handler\n", configuredLogGroup: "shared").isValid)
        let custom = LambdaLogContext(functionName: "handler", configuredLogGroup: "shared/group")
        XCTAssertTrue(custom.isCustomGroup)
        for name in ["2020/01/01/handler[$LATEST][abcd-1234]", "2026/10/03/handler[17][1234]"] {
            XCTAssertTrue(custom.ownsCustomStream(name))
        }
        for name in ["2026/10/03/handler-other[$LATEST][1234]", "2026/10/03/handler2[1][1234]",
                     "handler[$LATEST][1234]", "2026/10/03/[1]1234", "2026/10/03/handler[1][1234]\n"] {
            XCTAssertFalse(custom.ownsCustomStream(name))
        }
    }

    func testDirectGroupUsesFrozenMillisecondsFilterAndNeverUnmasks() async throws {
        let query = logQuery(pattern: "{ $.level = \"ERROR\" }")
        let stub = LogsStub(eventPages: [.init(events: [logAPIEvent("first", timestamp: query.startMilliseconds)])])
        let page = try await logService(stub).load(query: query, cursor: nil)
        let requests = await stub.requests()
        XCTAssertTrue(requests.streams.isEmpty)
        let request = try XCTUnwrap(requests.events.first)
        XCTAssertEqual(request.startTime, query.startMilliseconds)
        XCTAssertEqual(request.endTime, query.endMilliseconds)
        XCTAssertEqual(request.filterPattern, query.filterPattern)
        XCTAssertEqual(request.logGroupName, "/aws/lambda/handler")
        XCTAssertNil(request.logGroupIdentifier)
        XCTAssertNil(request.logStreamNames)
        XCTAssertNil(request.logStreamNamePrefix)
        XCTAssertEqual(request.unmask, false)
        XCTAssertEqual(request.limit, 500)
        XCTAssertEqual(page.events.map(\.id), ["first"])
        XCTAssertNil(page.cursor)
    }

    func testEmptyTokenPagesRemainResumableAndFinalMissingTokenCompletes() async throws {
        let query = logQuery()
        let stub = LogsStub(eventPages: [.init(nextToken: "a"), .init(nextToken: "b"), .init(nextToken: "c"),
                                        .init(events: [logAPIEvent("found", timestamp: query.endMilliseconds)])])
        let first = try await logService(stub).load(query: query, cursor: nil)
        XCTAssertTrue(first.events.isEmpty)
        XCTAssertNotNil(first.cursor)
        let next = try await logService(stub).load(query: query, cursor: first.cursor)
        XCTAssertEqual(next.events.map(\.id), ["found"])
        XCTAssertNil(next.cursor)
        let requests = await stub.requests()
        XCTAssertEqual(requests.events.map(\.nextToken), [nil, "a", "b", "c"])
    }

    func testSharedGroupEnumeratesAllDatesAndFiltersOnlyExactOwnedStreams() async throws {
        let query = logQuery(group: "shared")
        let old = "2020/01/01/handler[$LATEST][old]"
        let recent = "2026/10/03/handler[2][new]"
        let stub = LogsStub(streamPages: [
            .init(logStreams: [.init(logStreamName: old), .init(logStreamName: "2026/10/03/handler2[2][other]")], nextToken: "streams-2"),
            .init(logStreams: [.init(logStreamName: recent), .init(logStreamName: old)])
        ], eventPages: [.init(events: [logAPIEvent("mine", timestamp: query.startMilliseconds, stream: old)])])
        let page = try await logService(stub).load(query: query, cursor: nil)
        let requests = await stub.requests()
        XCTAssertEqual(requests.streams.map(\.nextToken), [nil, "streams-2"])
        XCTAssertTrue(requests.streams.allSatisfy { $0.logStreamNamePrefix == nil })
        XCTAssertEqual(requests.events.first?.logStreamNames, [old, recent])
        XCTAssertEqual(page.events.map(\.id), ["mine"])
    }

    func testSharedGroupBatchesAtMost100StreamsAndKeepsCursorForNextBatch() async throws {
        let names = (0..<101).map { "2026/10/03/handler[1][stream-\($0)]" }.sorted()
        let query = logQuery(group: "shared")
        let stub = LogsStub(streamPages: [.init(logStreams: names.map { .init(logStreamName: $0) })], eventPages: [
            .init(events: [logAPIEvent("one", timestamp: query.startMilliseconds, stream: names[0])]),
            .init(events: [logAPIEvent("two", timestamp: query.endMilliseconds, stream: names[100])])
        ])
        let first = try await logService(stub).load(query: query, cursor: nil)
        XCTAssertNotNil(first.cursor)
        let second = try await logService(stub).load(query: query, cursor: first.cursor)
        XCTAssertNil(second.cursor)
        let requests = await stub.requests()
        XCTAssertEqual(requests.events.map { $0.logStreamNames?.count }, [100, 1])
        XCTAssertEqual(requests.streams.count, 1)
    }

    func testNoMatchingStreamsNeverQueriesWholeSharedGroup() async throws {
        let stub = LogsStub(streamPages: [.init(logStreams: [.init(logStreamName: "2026/10/03/other[1][a]")])])
        let page = try await logService(stub).load(query: logQuery(group: "shared"), cursor: nil)
        XCTAssertTrue(page.events.isEmpty)
        XCTAssertNil(page.cursor)
        let requests = await stub.requests()
        XCTAssertTrue(requests.events.isEmpty)
    }

    func testIncompleteStreamEnumerationNeverReadsAnyEvents() async {
        let cases: [[CloudWatchLogs.DescribeLogStreamsResponse]] = [
            [.init(nextToken: "same"), .init(nextToken: "same")],
            (0..<100).map { .init(nextToken: "\($0)") }
        ]
        for pages in cases {
            let stub = LogsStub(streamPages: pages)
            do { _ = try await logService(stub).load(query: logQuery(group: "shared"), cursor: nil); XCTFail("Expected incomplete") }
            catch { XCTAssertEqual(error as? LambdaLogsError, .streamEnumerationLimit) }
            let requests = await stub.requests()
            XCTAssertTrue(requests.events.isEmpty)
        }
        XCTAssertFalse(LambdaLogsError.streamEnumerationLimit.localizedDescription.contains("Narrow the time range"))
        XCTAssertTrue(LambdaLogsError.streamEnumerationLimit.localizedDescription.contains("No shared-group events were read"))
    }

    func testSharedStreamEnumerationDeniedHasSpecificErrorAndNoEventRequest() async {
        let stub = LogsStub(streamError: AWSResponseError(errorCode: "AccessDeniedException"))
        do { _ = try await logService(stub).load(query: logQuery(group: "shared"), cursor: nil); XCTFail("Expected denial") }
        catch { XCTAssertEqual(error as? LambdaLogsError, .streamPermission) }
        let requests = await stub.requests()
        XCTAssertTrue(requests.events.isEmpty)
    }

    func testUnexpectedSharedStreamCannotLeakAnotherFunctionsLogs() async {
        let query = logQuery(group: "shared")
        let stub = LogsStub(streamPages: [.init(logStreams: [.init(logStreamName: "2026/10/03/handler[1][mine]")])],
                            eventPages: [.init(events: [logAPIEvent("secret", timestamp: query.startMilliseconds, stream: "2026/10/03/other[1][other]")])])
        do { _ = try await logService(stub).load(query: query, cursor: nil); XCTFail("Expected invalid response") }
        catch { XCTAssertEqual(error as? LambdaLogsError, .invalidResponse) }
    }

    func testEventDeduplicationSortingAndMalformedEvents() async throws {
        let query = logQuery()
        let stub = LogsStub(eventPages: [.init(events: [
            logAPIEvent("old", timestamp: query.startMilliseconds), logAPIEvent("new", timestamp: query.endMilliseconds),
            logAPIEvent("new", timestamp: query.endMilliseconds)
        ])])
        let page = try await logService(stub).load(query: query, cursor: nil)
        XCTAssertEqual(page.events.map(\.id), ["new", "old"])
        for invalid in [CloudWatchLogs.FilteredLogEvent(), logAPIEvent("outside", timestamp: query.startMilliseconds - 1)] {
            let bad = LogsStub(eventPages: [.init(events: [invalid])])
            do { _ = try await logService(bad).load(query: query, cursor: nil); XCTFail("Expected malformed") }
            catch { XCTAssertEqual(error as? LambdaLogsError, .invalidResponse) }
        }
    }

    func testEventTokenCyclesAreRejectedAcrossManualPages() async throws {
        let query = logQuery()
        let stub = LogsStub(eventPages: [
            .init(events: [logAPIEvent("one", timestamp: query.startMilliseconds)], nextToken: "repeat"),
            .init(nextToken: "repeat")
        ])
        let first = try await logService(stub).load(query: query, cursor: nil)
        do { _ = try await logService(stub).load(query: query, cursor: first.cursor); XCTFail("Expected cycle") }
        catch { XCTAssertEqual(error as? LambdaLogsError, .incompletePagination) }
    }

    func testQueryOrCursorMismatchIsRejectedBeforeAPI() async {
        let stub = LogsStub()
        let valid = logQuery()
        for query in [logQuery(pattern: String(repeating: "x", count: 1_025)), logQuery(group: "invalid:group"),
                      logQuery(scope: logScope(region: "")), logQuery(scope: logScope(account: "invalid"))] {
            do { _ = try await logService(stub).load(query: query, cursor: nil); XCTFail("Expected query rejection") }
            catch { XCTAssertEqual(error as? LambdaLogsError, .invalidQuery) }
        }
        let cursor = LambdaLogCursor(query: logQuery(pattern: "old"), streamBatches: nil, batchIndex: 0,
                                     nextToken: "x", seenTokens: ["x"], pagesRead: 1)
        do { _ = try await logService(stub).load(query: valid, cursor: cursor); XCTFail("Expected cursor rejection") }
        catch { XCTAssertEqual(error as? LambdaLogsError, .invalidCursor) }
        let requests = await stub.requests()
        XCTAssertTrue(requests.streams.isEmpty)
        XCTAssertTrue(requests.events.isEmpty)
    }

    func testErrorsAreSanitizedAndNeverReturnRawExceptionText() {
        let cases: [(Error, LambdaLogsError)] = [
            (AWSResponseError(errorCode: "AccessDeniedException"), .filterPermission),
            (AWSResponseError(errorCode: "ExpiredToken"), .credentials),
            (AWSResponseError(errorCode: "ThrottlingException"), .throttled),
            (AWSResponseError(errorCode: "ResourceNotFoundException"), .notFound),
            (AWSResponseError(errorCode: "InvalidParameterException"), .invalidPattern),
            (URLError(.notConnectedToInternet), .network),
            (NSError(domain: "private-token-secret", code: 1), .failed)
        ]
        for (error, expected) in cases {
            XCTAssertEqual(AWSLogsService.sanitized(error) as? LambdaLogsError, expected)
            XCTAssertFalse(AWSLogsService.sanitized(error).localizedDescription.contains("private-token-secret"))
        }
    }

    func testCancelledResponseDoesNotReturnEvents() async {
        let gate = TestGate()
        let query = logQuery()
        let service = AWSLogsService(streamLoader: { _ in .init() }, eventLoader: { _ in
            await gate.wait()
            return .init(events: [logAPIEvent("cancelled", timestamp: query.startMilliseconds)])
        })
        let task = Task { try await service.load(query: query, cursor: nil) }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

@MainActor
final class LambdaLogsViewModelTests: XCTestCase {
    func testNoProfileAndConfigureNeverQueryUntilSearch() async {
        let probe = LogVMProbe()
        let vm = makeVM(probe)
        vm.search()
        vm.loadMore()
        vm.configure(scope: logScope(), context: logContext())
        let before = await probe.count()
        XCTAssertEqual(before, 0)
        vm.search()
        await vm.waitForCurrentLoad()
        let after = await probe.count()
        XCTAssertEqual(after, 1)
        XCTAssertTrue(vm.hasSearched)
        XCTAssertFalse(vm.hasMore)
        XCTAssertEqual(vm.query?.endTime, fixedLogDate)
        XCTAssertEqual(vm.query?.startTime, fixedLogDate.addingTimeInterval(-3_600))
    }

    func testChangingDraftsClearsSearchWithoutAutoRequest() async {
        let probe = LogVMProbe()
        let vm = makeVM(probe)
        vm.configure(scope: logScope(), context: logContext())
        vm.search()
        await vm.waitForCurrentLoad()
        vm.filterPattern = "ERROR"
        XCTAssertNil(vm.query)
        XCTAssertFalse(vm.hasSearched)
        vm.search()
        await vm.waitForCurrentLoad()
        vm.timeRange = .day
        XCTAssertNil(vm.query)
        let count = await probe.count()
        XCTAssertEqual(count, 2)
    }

    func testLateSuccessOrFailureCannotRepopulateAfterScopeChange() async {
        for failure in [false, true] {
            let gate = TestGate()
            let vm = LambdaLogsViewModel(loader: { query, _ in
                await gate.wait()
                if failure { throw LambdaLogsError.filterPermission }
                return LambdaLogPage(query: query, events: [logEvent("stale")], cursor: nil)
            }, now: { fixedLogDate })
            vm.configure(scope: logScope(), context: logContext())
            vm.search()
            await gate.waitForEntry()
            let waiter = Task { await vm.waitForCurrentLoad() }
            await Task.yield()
            vm.configure(scope: logScope(region: "eu-west-1"), context: logContext())
            await gate.open()
            await waiter.value
            XCTAssertTrue(vm.events.isEmpty)
            XCTAssertNil(vm.query)
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
            XCTAssertEqual(vm.scope?.region, "eu-west-1")
        }
    }

    func testResetAndDraftChangesInvalidateCancelledResponses() async {
        for operation in ["reset", "filter", "range", "function"] {
            let gate = TestGate()
            let vm = LambdaLogsViewModel(loader: { query, _ in
                await gate.wait()
                return LambdaLogPage(query: query, events: [logEvent("old")], cursor: nil)
            }, now: { fixedLogDate })
            vm.configure(scope: logScope(), context: logContext())
            vm.search()
            await gate.waitForEntry()
            let waiter = Task { await vm.waitForCurrentLoad() }
            await Task.yield()
            switch operation {
            case "reset": vm.reset()
            case "filter": vm.filterPattern = "changed"
            case "range": vm.timeRange = .sixHours
            default: vm.configure(scope: logScope(), context: LambdaLogContext(functionName: "other", configuredLogGroup: nil))
            }
            await gate.open()
            await waiter.value
            XCTAssertTrue(vm.events.isEmpty)
            XCTAssertNil(vm.query)
            XCTAssertNil(vm.error)
        }
    }

    func testExplicitCancelKeepsContextAndMarksSearchIncomplete() async {
        let gate = TestGate()
        let vm = LambdaLogsViewModel(loader: { query, _ in
            await gate.wait()
            return LambdaLogPage(query: query, events: [logEvent("late")], cursor: nil)
        }, now: { fixedLogDate })
        vm.configure(scope: logScope(), context: logContext())
        vm.search()
        await gate.waitForEntry()
        let waiter = Task { await vm.waitForCurrentLoad() }
        await Task.yield()
        vm.cancelLoading()
        await gate.open()
        await waiter.value
        XCTAssertEqual(vm.scope, logScope())
        XCTAssertEqual(vm.context, logContext())
        XCTAssertNotNil(vm.query)
        XCTAssertNotNil(vm.error)
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.events.isEmpty)
    }

    func testLoadMoreDeduplicatesFreezesQueryAndPreservesRowsOnFailure() async {
        let probe = LogVMProbe(mode: .pages)
        let vm = makeVM(probe)
        vm.configure(scope: logScope(), context: logContext())
        vm.search()
        await vm.waitForCurrentLoad()
        let query = vm.query
        XCTAssertTrue(vm.hasMore)
        vm.loadMore()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.events.map(\.id), ["two", "one"])
        XCTAssertEqual(vm.query, query)
        vm.loadMore()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.events.count, 2)
        XCTAssertNotNil(vm.error)
        XCTAssertTrue(vm.hasMore)
    }

    func testEmptyPageWithCursorIsNotDisplayedAsComplete() async {
        let probe = LogVMProbe(mode: .emptyCursor)
        let vm = makeVM(probe)
        vm.configure(scope: logScope(), context: logContext())
        vm.search()
        await vm.waitForCurrentLoad()
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertTrue(vm.hasMore)
        XCTAssertTrue(vm.hasSearched)
        XCTAssertFalse(vm.limitReached)
    }

    func testMaximumDisplayCountStopsFurtherRequestsWithLimitState() async {
        let probe = LogVMProbe(mode: .limit)
        let vm = makeVM(probe)
        vm.configure(scope: logScope(), context: logContext())
        vm.search()
        await vm.waitForCurrentLoad()
        XCTAssertEqual(vm.events.count, 5_000)
        XCTAssertTrue(vm.limitReached)
        XCTAssertFalse(vm.hasMore)
        vm.loadMore()
        let count = await probe.count()
        XCTAssertEqual(count, 1)
    }

    func testLargeMessageBudgetMarksIncompleteWithoutRetainingOversizedPayload() async {
        let messageSize = LambdaLogsViewModel.maximumMessageBytes + 1
        let vm = LambdaLogsViewModel(loader: { query, _ in
            let event = LambdaLogEvent(id: "large", timestamp: query.endTime, ingestionTime: nil, streamName: "stream",
                                       message: String(repeating: "a", count: messageSize))
            return .init(query: query, events: [event], cursor: nil)
        }, now: { fixedLogDate })
        vm.configure(scope: logScope(), context: logContext())
        vm.search()
        await vm.waitForCurrentLoad()
        XCTAssertTrue(vm.limitReached)
        XCTAssertFalse(vm.hasMore)
        XCTAssertTrue(vm.events.isEmpty)
    }

    func testInvalidConfigurationOrPatternDoesNotLoadAndMismatchedResponseIsRejected() async {
        let probe = LogVMProbe()
        let vm = makeVM(probe)
        vm.configure(scope: logScope(), context: LambdaLogContext(functionName: "", configuredLogGroup: nil))
        vm.search()
        vm.configure(scope: logScope(), context: logContext())
        vm.filterPattern = String(repeating: "x", count: 1_025)
        vm.search()
        XCTAssertNotNil(vm.error)
        let count = await probe.count()
        XCTAssertEqual(count, 0)
        let bad = LambdaLogsViewModel(loader: { _, _ in .init(query: logQuery(pattern: "different"), events: [logEvent("bad")], cursor: nil) })
        bad.configure(scope: logScope(), context: logContext())
        bad.search()
        await bad.waitForCurrentLoad()
        XCTAssertTrue(bad.events.isEmpty)
        XCTAssertEqual(bad.error, LambdaLogsError.invalidResponse.localizedDescription)
    }

    private func makeVM(_ probe: LogVMProbe) -> LambdaLogsViewModel {
        LambdaLogsViewModel(loader: { try await probe.load($0, cursor: $1) }, now: { fixedLogDate })
    }
}

private let fixedLogDate = Date(timeIntervalSince1970: 1_790_000_000.123)

private func logScope(region: String = "us-east-1", account: String = "111122223333") -> MonitoringScope {
    MonitoringScope(profile: AWSProfile(name: "test", region: region, ssoStartURL: nil, ssoRegion: nil,
                                        ssoAccountID: nil, ssoRoleName: nil),
                    identity: AWSIdentity(account: account, arn: "arn:aws:sts::\(account):assumed-role/Test/session", userID: "test"),
                    region: region)
}

private func logContext() -> LambdaLogContext { LambdaLogContext(functionName: "handler", configuredLogGroup: nil) }

private func logQuery(group: String? = nil, pattern: String = "", scope: MonitoringScope = logScope()) -> LambdaLogQuery {
    LambdaLogQuery(scope: scope, context: LambdaLogContext(functionName: "handler", configuredLogGroup: group),
                   startTime: fixedLogDate.addingTimeInterval(-3_600), endTime: fixedLogDate, filterPattern: pattern)
}

private func logAPIEvent(_ id: String, timestamp: Int64, stream: String = "2026/10/03/[$LATEST]1234") -> CloudWatchLogs.FilteredLogEvent {
    .init(eventId: id, ingestionTime: timestamp + 1, logStreamName: stream, message: "line one\nline two", timestamp: timestamp)
}

private func logEvent(_ id: String, offset: TimeInterval = 0) -> LambdaLogEvent {
    LambdaLogEvent(id: id, timestamp: fixedLogDate.addingTimeInterval(offset), ingestionTime: nil, streamName: "stream", message: id)
}

private func logService(_ stub: LogsStub) -> AWSLogsService {
    AWSLogsService(streamLoader: { try await stub.streams($0) }, eventLoader: { try await stub.events($0) })
}

private actor LogsStub {
    private var streamPages: [CloudWatchLogs.DescribeLogStreamsResponse]
    private var eventPages: [CloudWatchLogs.FilterLogEventsResponse]
    private let streamError: Error?
    private var streamRequests: [CloudWatchLogs.DescribeLogStreamsRequest] = []
    private var eventRequests: [CloudWatchLogs.FilterLogEventsRequest] = []

    init(streamPages: [CloudWatchLogs.DescribeLogStreamsResponse] = [],
         eventPages: [CloudWatchLogs.FilterLogEventsResponse] = [], streamError: Error? = nil) {
        self.streamPages = streamPages
        self.eventPages = eventPages
        self.streamError = streamError
    }

    func streams(_ request: CloudWatchLogs.DescribeLogStreamsRequest) throws -> CloudWatchLogs.DescribeLogStreamsResponse {
        streamRequests.append(request)
        if let streamError { throw streamError }
        return streamPages.isEmpty ? .init() : streamPages.removeFirst()
    }

    func events(_ request: CloudWatchLogs.FilterLogEventsRequest) throws -> CloudWatchLogs.FilterLogEventsResponse {
        eventRequests.append(request)
        return eventPages.isEmpty ? .init() : eventPages.removeFirst()
    }

    func requests() -> (streams: [CloudWatchLogs.DescribeLogStreamsRequest], events: [CloudWatchLogs.FilterLogEventsRequest]) {
        (streamRequests, eventRequests)
    }
}

private actor LogVMProbe {
    enum Mode: Sendable { case empty, pages, emptyCursor, limit }
    private let mode: Mode
    private var calls = 0
    init(mode: Mode = .empty) { self.mode = mode }
    func count() -> Int { calls }

    func load(_ query: LambdaLogQuery, cursor: LambdaLogCursor?) throws -> LambdaLogPage {
        calls += 1
        let next = LambdaLogCursor(query: query, streamBatches: nil, batchIndex: 0,
                                   nextToken: "\(calls)", seenTokens: ["\(calls)"], pagesRead: calls)
        switch mode {
        case .empty: return .init(query: query, events: [], cursor: nil)
        case .emptyCursor: return .init(query: query, events: [], cursor: next)
        case .pages:
            if calls > 2 { throw LambdaLogsError.network }
            return .init(query: query, events: calls == 1 ? [logEvent("one", offset: -1)] : [logEvent("one", offset: -1), logEvent("two")], cursor: next)
        case .limit: return .init(query: query, events: (0..<5_001).map { logEvent("\($0)") }, cursor: next)
        }
    }
}
