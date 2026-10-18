import Foundation
import SotoCloudWatchLogs
import XCTest
@testable import AWSPlatform

final class CloudWatchLogsByteIdentityTests: XCTestCase {
    private let composed = "app/\u{e9}"
    private let decomposed = "app/e\u{301}"

    func testStreamModelsAndQueriesKeepDistinctUTF8Identity() {
        let streams = [byteStream(composed), byteStream(decomposed)]
        XCTAssertEqual(Set(streams.map(\.id)).count, 2)
        XCTAssertEqual(Set(streams).count, 2)
        let queries = [logsBrowserQuery(stream: composed), logsBrowserQuery(stream: decomposed)]
        XCTAssertNotEqual(queries[0], queries[1])
        XCTAssertEqual(Set(queries).count, 2)
        XCTAssertNotEqual(logsBrowserQuery(pattern: "\u{e9}"), logsBrowserQuery(pattern: "e\u{301}"))
    }

    func testDistinctCanonicalStreamNamesAcrossPagesAreBothRetained() async throws {
        let group = logsBrowserGroup()
        let fixture = LogsBrowserFixture(streams: [
            .init(logStreams: [.init(arn: group.arn + ":log-stream:" + composed, logStreamName: composed)], nextToken: "next"),
            .init(logStreams: [.init(arn: group.arn + ":log-stream:" + decomposed, logStreamName: decomposed)])
        ])
        let rows = try await fixture.service.loadStreams(scope: logsVersionsScope(), group: group)
        XCTAssertEqual(Set(rows.map(\.id)), [Data(composed.utf8), Data(decomposed.utf8)])
        let inputs = await fixture.streamInputs
        XCTAssertEqual(inputs.map(\.nextToken), [nil, "next"])
        let duplicate = LogsBrowserFixture(streams: [.init(logStreams: [
            .init(logStreamName: composed), .init(logStreamName: composed)
        ])])
        await assertError(.invalidResponse) { _ = try await duplicate.service.loadStreams(scope: logsVersionsScope(), group: group) }
    }

    func testCanonicalButByteDifferentStreamARNAndEventSourceAreRejected() async {
        let group = logsBrowserGroup()
        let streams = LogsBrowserFixture(streams: [.init(logStreams: [
            .init(arn: group.arn + ":log-stream:" + decomposed, logStreamName: composed)
        ])])
        await assertError(.invalidResponse) { _ = try await streams.service.loadStreams(scope: logsVersionsScope(), group: group) }
        let query = logsBrowserQuery(stream: composed)
        let events = LogsBrowserFixture(events: [.init(events: [.init(eventId: "foreign", logStreamName: decomposed,
            timestamp: query.startMilliseconds)])])
        await assertError(.invalidResponse) { _ = try await events.service.loadEvents(query: query, cursor: nil) }
    }

    func testEventCursorCannotCrossCanonicalStreamOrFilterBoundaries() async throws {
        let query = logsBrowserQuery(stream: composed, pattern: "\u{e9}")
        let fixture = LogsBrowserFixture(events: [.init(nextToken: "next")])
        let first = try await fixture.service.loadEvents(query: query, cursor: nil)
        for foreign in [logsBrowserQuery(stream: decomposed, pattern: "\u{e9}"),
                        logsBrowserQuery(stream: composed, pattern: "e\u{301}")] {
            await assertError(.invalidCursor) { _ = try await fixture.service.loadEvents(query: foreign, cursor: first.cursor) }
        }
        let inputs = await fixture.eventInputs
        XCTAssertEqual(inputs.count, 1)
    }

    func testEachCanonicalStreamCanReadCompleteEventPaginationWithOriginalBytes() async throws {
        for stream in [composed, decomposed] {
            let query = logsBrowserQuery(stream: stream)
            let fixture = LogsBrowserFixture(events: [
                .init(events: [.init(eventId: "first", logStreamName: stream, timestamp: query.startMilliseconds)], nextToken: "next"),
                .init(events: [.init(eventId: "second", logStreamName: stream, timestamp: query.endMilliseconds)])
            ])
            let first = try await fixture.service.loadEvents(query: query, cursor: nil)
            let last = try await fixture.service.loadEvents(query: query, cursor: try XCTUnwrap(first.cursor))
            XCTAssertEqual(first.events.map(\.id) + last.events.map(\.id), ["first", "second"])
            XCTAssertNil(last.cursor)
            let inputs = await fixture.eventInputs
            XCTAssertEqual(inputs.map { $0.logStreamNames?.map { Data($0.utf8) } }, [[Data(stream.utf8)], [Data(stream.utf8)]])
            XCTAssertTrue(inputs.allSatisfy { $0.unmask == false })
        }
    }

    func testUnicodeGroupNamesStillFailCurrentGroupValidation() async {
        let group = logsBrowserGroup("/\u{e9}")
        XCTAssertFalse(CloudWatchLogsBrowserQuery.owns(group: group, scope: logsVersionsScope()))
        let fixture = LogsBrowserFixture()
        await assertError(.invalidScope) { _ = try await fixture.service.loadStreams(scope: logsVersionsScope(), group: group) }
        let inputs = await fixture.streamInputs
        XCTAssertTrue(inputs.isEmpty)
    }

    func testControlCharacterStreamNamesKeepExactARNAndFilterRequestResponseBytes() async throws {
        let group = logsBrowserGroup()
        let names = ["app/with\ttab", "app/with\nnewline", "app/with\0nul"]
        XCTAssertTrue(names.allSatisfy(CloudWatchLogsBrowserQuery.validStream))
        let fixture = LogsBrowserFixture(streams: [.init(logStreams: names.map {
            .init(arn: group.arn + ":log-stream:" + $0, logStreamName: $0)
        })])
        let streams = try await fixture.service.loadStreams(scope: logsVersionsScope(), group: group)
        XCTAssertEqual(Set(streams.map(\.id)), Set(names.map { Data($0.utf8) }))
        XCTAssertEqual(streams.count, names.count)
        for name in names {
            let query = logsBrowserQuery(stream: name)
            XCTAssertTrue(query.isValid)
            let events = LogsBrowserFixture(events: [.init(events: [.init(eventId: "event", logStreamName: name,
                message: "example", timestamp: query.startMilliseconds)])])
            let page = try await events.service.loadEvents(query: query, cursor: nil)
            XCTAssertEqual(page.events.first.map { Data($0.streamName.utf8) }, Data(name.utf8))
            let requests = await events.eventInputs
            XCTAssertEqual(requests.first?.logStreamNames?.map { Data($0.utf8) }, [Data(name.utf8)])
            XCTAssertEqual(requests.first?.unmask, false)

            let wrongARN = LogsBrowserFixture(streams: [.init(logStreams: [
                .init(arn: group.arn + ":log-stream:" + name + "other", logStreamName: name)
            ])])
            await assertError(.invalidResponse) { _ = try await wrongARN.service.loadStreams(scope: logsVersionsScope(), group: group) }
            let wrongSource = LogsBrowserFixture(events: [.init(events: [.init(eventId: "event", logStreamName: name + "other",
                timestamp: query.startMilliseconds)])])
            await assertError(.invalidResponse) { _ = try await wrongSource.service.loadEvents(query: query, cursor: nil) }
        }
    }

    func testEmptyColonAsteriskAndOversizedStreamsStillRejectBeforeEventRequest() async {
        let group = logsBrowserGroup()
        for name in ["", "app:stream", "app*stream", String(repeating: "a", count: 513)] {
            XCTAssertFalse(CloudWatchLogsBrowserQuery.validStream(name))
            let fixture = LogsBrowserFixture(streams: [.init(logStreams: [.init(logStreamName: name)])])
            await assertError(.invalidResponse) { _ = try await fixture.service.loadStreams(scope: logsVersionsScope(), group: group) }
            await assertError(.invalidScope) { _ = try await fixture.service.loadEvents(query: logsBrowserQuery(stream: name), cursor: nil) }
            let inputs = await fixture.eventInputs
            XCTAssertTrue(inputs.isEmpty)
        }
    }

    private func assertError(_ expected: CloudWatchLogsBrowserError, operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected rejection", file: file, line: line) }
        catch { XCTAssertEqual(error as? CloudWatchLogsBrowserError, expected, file: file, line: line) }
    }
}

@MainActor
final class CloudWatchLogsByteIdentityViewModelTests: XCTestCase {
    func testActualPickerBindingSwitchesBetweenCanonicalStreamsAndInvalidatesEvents() async {
        let group = logsBrowserGroup()
        let composed = "app/\u{e9}"
        let decomposed = "app/e\u{301}"
        let vm = byteVM(group: group, streams: [composed, decomposed])
        await prepare(vm, group: group)
        XCTAssertEqual(vm.streams.count, 2)
        let detail = CloudWatchLogGroupDetailView(vm: vm)
        detail.streamSelection.wrappedValue = Data(composed.utf8)
        XCTAssertEqual(detail.streamSelection.wrappedValue, Data(composed.utf8))
        vm.searchEvents(now: Date(timeIntervalSince1970: 1_700_003_600))
        await vm.waitForLoading()
        XCTAssertEqual(vm.events.count, 1)
        XCTAssertTrue(vm.hasMoreEvents)
        detail.streamSelection.wrappedValue = Data(decomposed.utf8)
        XCTAssertEqual(vm.selectedStream.map { Data($0.utf8) }, Data(decomposed.utf8))
        XCTAssertEqual(detail.streamSelection.wrappedValue, Data(decomposed.utf8))
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertNil(vm.query)
        XCTAssertFalse(vm.hasMoreEvents)
        XCTAssertFalse(vm.hasSearched)
        XCTAssertTrue(vm.canSearch)
        vm.searchEvents(now: Date(timeIntervalSince1970: 1_700_003_600))
        await vm.waitForLoading()
        XCTAssertEqual(vm.events.first.map { Data($0.streamName.utf8) }, Data(decomposed.utf8))
        detail.streamSelection.wrappedValue = nil
        XCTAssertNil(vm.selectedStream)
        XCTAssertNil(detail.streamSelection.wrappedValue)
    }

    func testCanonicalUnknownStreamCannotBeSearchedThroughDirectSelection() async {
        let group = logsBrowserGroup()
        let vm = byteVM(group: group, streams: ["app/\u{e9}"])
        await prepare(vm, group: group)
        vm.selectedStream = "app/e\u{301}"
        XCTAssertFalse(vm.canSearch)
        vm.searchEvents()
        XCTAssertFalse(vm.hasSearched)
    }

    func testCanonicalFilterChangeClearsPreviouslyLoadedQuery() async {
        let group = logsBrowserGroup()
        let vm = byteVM(group: group, streams: [])
        await prepare(vm, group: group)
        vm.filterPattern = "\u{e9}"
        vm.searchEvents(now: Date(timeIntervalSince1970: 1_700_003_600))
        await vm.waitForLoading()
        XCTAssertFalse(vm.events.isEmpty)
        vm.filterPattern = "e\u{301}"
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertNil(vm.query)
        XCTAssertFalse(vm.hasMoreEvents)
    }

    func testLateSuccessAndFailureCannotReturnAfterPickerSwitchesCanonicalStream() async {
        for failure in [false, true] {
            let group = logsBrowserGroup()
            let gate = LogsVersionsGate()
            let streams = [byteStream("app/\u{e9}"), byteStream("app/e\u{301}")]
            let vm = CloudWatchLogsBrowserViewModel(groupLoader: { _ in [group] }, streamLoader: { _, _ in streams },
                eventLoader: { query, _ in
                    await gate.enter()
                    if failure { throw LogsVersionsFixtureError("AccessDeniedException") }
                    return .init(query: query, events: [byteEvent(query)], cursor: nil)
                })
            await prepare(vm, group: group)
            let detail = CloudWatchLogGroupDetailView(vm: vm)
            detail.streamSelection.wrappedValue = Data("app/\u{e9}".utf8)
            vm.searchEvents(now: Date(timeIntervalSince1970: 1_700_003_600))
            await gate.waitForEntry()
            let pending = Task { await vm.waitForLoading() }
            await Task.yield()
            detail.streamSelection.wrappedValue = Data("app/e\u{301}".utf8)
            await gate.open(); await pending.value
            XCTAssertTrue(vm.events.isEmpty)
            XCTAssertNil(vm.eventError)
            XCTAssertFalse(vm.isEventsLoading)
            XCTAssertNil(vm.query)
            XCTAssertFalse(vm.hasSearched)
        }
    }

    func testCanonicalForeignReturnedPageOrCursorCannotBeDisplayed() async {
        let group = logsBrowserGroup()
        for wrongPage in [true, false] {
            let vm = CloudWatchLogsBrowserViewModel(groupLoader: { _ in [group] }, streamLoader: { _, _ in [byteStream("app/\u{e9}")] },
                eventLoader: { query, _ in
                    let foreign = CloudWatchLogsBrowserQuery(scope: query.scope, group: query.group, streamName: "app/e\u{301}",
                        startTime: query.startTime, endTime: query.endTime, filterPattern: query.filterPattern)
                    return .init(query: wrongPage ? foreign : query, events: [byteEvent(query)],
                        cursor: .init(query: foreign, nextToken: "next", seenTokens: ["next"], pagesRead: 1))
                })
            await prepare(vm, group: group)
            vm.selectedStream = "app/\u{e9}"
            vm.searchEvents(now: Date(timeIntervalSince1970: 1_700_003_600))
            await vm.waitForLoading()
            XCTAssertTrue(vm.events.isEmpty)
            XCTAssertNotNil(vm.eventError)
        }
    }

    private func prepare(_ vm: CloudWatchLogsBrowserViewModel, group: CloudWatchLogGroup) async {
        vm.configure(scope: logsVersionsScope())
        vm.loadIfNeeded(); await vm.waitForLoading()
        vm.selectedGroup = group; await vm.waitForLoading()
    }

    private func byteVM(group: CloudWatchLogGroup, streams: [String]) -> CloudWatchLogsBrowserViewModel {
        let rows = streams.map(byteStream)
        return .init(groupLoader: { _ in [group] }, streamLoader: { _, _ in rows }, eventLoader: { query, _ in
            .init(query: query, events: [byteEvent(query)],
                  cursor: .init(query: query, nextToken: "next", seenTokens: ["next"], pagesRead: 1))
        })
    }
}

private func byteStream(_ name: String) -> CloudWatchLogStream {
    .init(name: name, createdAt: nil, firstEventAt: nil, lastEventAt: nil)
}

private func byteEvent(_ query: CloudWatchLogsBrowserQuery) -> LambdaLogEvent {
    .init(id: "event", timestamp: query.startTime, ingestionTime: nil, streamName: query.streamName ?? "app", message: "example")
}
