import Foundation
import XCTest
@testable import AWSPlatform

@MainActor
final class CloudWatchLogsBrowserViewModelTests: XCTestCase {
    func testNoScopeDoesNotLoadAndGroupsDoNotAutoSelectOrReadEvents() async throws {
        let fixture = LogsBrowserFixture()
        let service = fixture.service
        let vm = CloudWatchLogsBrowserViewModel(groupLoader: { try await service.loadGroups(scope: $0) },
            streamLoader: { try await service.loadStreams(scope: $0, group: $1) },
            eventLoader: { try await service.loadEvents(query: $0, cursor: $1) })
        vm.loadIfNeeded()
        await vm.waitForLoading()
        var requests = await fixture.groupInputs.count
        XCTAssertEqual(requests, 0)
        vm.configure(scope: logsVersionsScope())
        vm.loadIfNeeded()
        await vm.waitForLoading()
        vm.loadIfNeeded()
        await vm.waitForLoading()
        requests = await fixture.groupInputs.count
        XCTAssertEqual(requests, 1)
        XCTAssertNil(vm.selectedGroup)
        let eventRequests = await fixture.eventInputs.count
        XCTAssertEqual(eventRequests, 0)
    }

    func testGroupSelectionLoadsOnlyMetadataUntilExplicitSearch() async {
        let group = logsBrowserGroup()
        let vm = makeVM(groups: [group])
        vm.configure(scope: logsVersionsScope())
        vm.loadIfNeeded()
        await vm.waitForLoading()
        vm.selectedGroup = group
        await vm.waitForLoading()
        XCTAssertEqual(vm.streams.map(\.name), ["application/stream"])
        XCTAssertFalse(vm.hasSearched)
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertTrue(vm.canSearch)
        vm.searchEvents(now: Date(timeIntervalSince1970: 1_700_003_600))
        await vm.waitForLoading()
        XCTAssertTrue(vm.hasSearched)
        XCTAssertEqual(vm.events.map(\.id), ["one"])
    }

    func testTimeFilterOrStreamChangeClearsOldSearchAndCannotUseUnknownStream() async {
        let group = logsBrowserGroup()
        let vm = makeVM(groups: [group])
        await prepare(vm, group: group)
        for edit in [0, 1, 2] {
            vm.searchEvents(now: Date(timeIntervalSince1970: 1_700_003_600))
            await vm.waitForLoading()
            XCTAssertFalse(vm.events.isEmpty)
            if edit == 0 { vm.timeRange = .day }
            if edit == 1 { vm.filterPattern = "ERROR" }
            if edit == 2 { vm.selectedStream = "application/stream" }
            XCTAssertTrue(vm.events.isEmpty)
            XCTAssertFalse(vm.hasSearched)
        }
        vm.selectedStream = "not-listed"
        XCTAssertFalse(vm.canSearch)
        vm.searchEvents()
        XCTAssertFalse(vm.hasSearched)
    }

    func testForeignSelectedGroupIsRejectedAndProfileChangesClearEverything() async {
        let group = logsBrowserGroup()
        let vm = makeVM(groups: [group])
        await prepare(vm, group: group)
        vm.searchEvents(now: Date(timeIntervalSince1970: 1_700_003_600))
        await vm.waitForLoading()
        vm.selectedGroup = logsBrowserGroup("/unlisted")
        XCTAssertNil(vm.selectedGroup)
        XCTAssertTrue(vm.events.isEmpty)
        for scope in [logsVersionsScope(profile: "other"), logsVersionsScope(role: "Other"),
                      logsVersionsScope(configPath: "/different/config"), logsVersionsScope(region: "us-east-1")] {
            vm.configure(scope: scope)
            XCTAssertTrue(vm.groups.isEmpty)
            XCTAssertNil(vm.selectedGroup)
            XCTAssertNil(vm.query)
        }
        vm.configure(scope: nil)
        XCTAssertNil(vm.scope)
    }

    func testLateGroupsCannotReappearAfterScopeChange() async {
        let gate = LogsVersionsGate()
        let oldScope = logsVersionsScope()
        let group = logsBrowserGroup()
        let vm = CloudWatchLogsBrowserViewModel(groupLoader: { _ in await gate.enter(); return [group] },
            streamLoader: { _, _ in [] }, eventLoader: { query, _ in .init(query: query, events: [], cursor: nil) })
        vm.configure(scope: oldScope)
        vm.loadIfNeeded()
        await gate.waitForEntry()
        vm.configure(scope: logsVersionsScope(profile: "different"))
        await gate.open()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(vm.groups.isEmpty)
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isLoading)
    }

    func testLateEventsAndErrorsCannotReappearAfterFilterChange() async {
        for failure in [false, true] {
            let gate = LogsVersionsGate()
            let group = logsBrowserGroup()
            let vm = CloudWatchLogsBrowserViewModel(groupLoader: { _ in [group] }, streamLoader: { _, _ in [] },
                eventLoader: { query, _ in
                    await gate.enter()
                    if failure { throw LogsVersionsFixtureError("AccessDeniedException") }
                    return .init(query: query, events: [selfEvent(query)], cursor: nil)
                })
            await prepare(vm, group: group)
            vm.searchEvents(now: Date(timeIntervalSince1970: 1_700_003_600))
            await gate.waitForEntry()
            vm.filterPattern = "new-filter"
            await gate.open()
            for _ in 0..<10 { await Task.yield() }
            XCTAssertTrue(vm.events.isEmpty)
            XCTAssertNil(vm.eventError)
            XCTAssertFalse(vm.isEventsLoading)
        }
    }

    func testSecondPageFailurePreservesRowsAndIncompleteCursor() async {
        let group = logsBrowserGroup()
        let vm = CloudWatchLogsBrowserViewModel(groupLoader: { _ in [group] }, streamLoader: { _, _ in [] },
            eventLoader: { query, cursor in
                if cursor != nil { throw LogsVersionsFixtureError("AccessDeniedException") }
                return .init(query: query, events: [selfEvent(query)],
                    cursor: .init(query: query, nextToken: "next", seenTokens: ["next"], pagesRead: 1))
            })
        await prepare(vm, group: group)
        vm.searchEvents(now: Date(timeIntervalSince1970: 1_700_003_600))
        await vm.waitForLoading()
        vm.loadMoreEvents()
        await vm.waitForLoading()
        XCTAssertEqual(vm.events.count, 1)
        XCTAssertTrue(vm.hasMoreEvents)
        XCTAssertNotNil(vm.eventError)
        XCTAssertFalse(vm.eventError!.contains("private-test-content"))
    }

    func testDisplayBytesAreBoundedAndLimitIsExplicit() async {
        let group = logsBrowserGroup()
        let message = String(repeating: "x", count: 1_024 * 1_024)
        let vm = CloudWatchLogsBrowserViewModel(groupLoader: { _ in [group] }, streamLoader: { _, _ in [] },
            eventLoader: { query, _ in .init(query: query, events: (0..<5).map {
                LambdaLogEvent(id: String($0), timestamp: query.startTime, ingestionTime: nil, streamName: "app", message: message)
            }, cursor: .init(query: query, nextToken: "next", seenTokens: ["next"], pagesRead: 1)) })
        await prepare(vm, group: group)
        vm.searchEvents(now: Date(timeIntervalSince1970: 1_700_003_600))
        await vm.waitForLoading()
        XCTAssertEqual(vm.events.count, 4)
        XCTAssertTrue(vm.limitReached)
        XCTAssertFalse(vm.hasMoreEvents)
    }

    func testCancelInvalidatesPendingEventsButPreservesCompletedMetadata() async {
        let gate = LogsVersionsGate()
        let group = logsBrowserGroup()
        let vm = CloudWatchLogsBrowserViewModel(groupLoader: { _ in [group] }, streamLoader: { _, _ in [] },
            eventLoader: { query, _ in await gate.enter(); return .init(query: query, events: [selfEvent(query)], cursor: nil) })
        await prepare(vm, group: group)
        vm.searchEvents(now: Date(timeIntervalSince1970: 1_700_003_600))
        await gate.waitForEntry()
        vm.cancelLoading()
        await gate.open()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(vm.groups, [group])
        XCTAssertEqual(vm.selectedGroup, group)
        XCTAssertTrue(vm.events.isEmpty)
        XCTAssertNotNil(vm.eventError)
        XCTAssertFalse(vm.isEventsLoading)
    }

    private func makeVM(groups: [CloudWatchLogGroup]) -> CloudWatchLogsBrowserViewModel {
        CloudWatchLogsBrowserViewModel(groupLoader: { _ in groups }, streamLoader: { _, _ in [
            .init(name: "application/stream", createdAt: nil, firstEventAt: nil, lastEventAt: nil)
        ] }, eventLoader: { query, _ in .init(query: query, events: [selfEvent(query)], cursor: nil) })
    }

    private func prepare(_ vm: CloudWatchLogsBrowserViewModel, group: CloudWatchLogGroup) async {
        vm.configure(scope: logsVersionsScope())
        vm.loadIfNeeded()
        await vm.waitForLoading()
        vm.selectedGroup = group
        await vm.waitForLoading()
    }
}

private func selfEvent(_ query: CloudWatchLogsBrowserQuery) -> LambdaLogEvent {
    .init(id: "one", timestamp: query.startTime, ingestionTime: nil, streamName: query.streamName ?? "app", message: "example")
}
