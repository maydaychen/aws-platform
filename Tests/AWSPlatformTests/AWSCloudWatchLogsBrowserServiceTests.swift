import Foundation
import SotoCloudWatchLogs
import XCTest
@testable import AWSPlatform

final class AWSCloudWatchLogsBrowserServiceTests: XCTestCase {
    func testGroupsAreCurrentAccountOnlyAndPreserveMissingMetadata() async throws {
        let group = logsBrowserGroup()
        let fixture = LogsBrowserFixture(groups: [.init(logGroups: [.init(arn: group.arn + ":*", logGroupName: group.name)])])
        let rows = try await fixture.service.loadGroups(scope: logsVersionsScope())
        XCTAssertEqual(rows, [group])
        XCTAssertNil(rows.first?.retentionDays)
        let inputs = await fixture.groupInputs
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].includeLinkedAccounts, false)
        XCTAssertNil(inputs[0].accountIdentifiers)
        XCTAssertEqual(inputs[0].limit, 50)
        XCTAssertNil(inputs[0].logGroupNamePattern)
    }

    func testGroupsEnumerateAllPagesWithoutSelectingAnything() async throws {
        let first = logsBrowserGroup("/a")
        let second = logsBrowserGroup("/b")
        let fixture = LogsBrowserFixture(groups: [
            .init(logGroups: [.init(logGroupArn: first.arn, logGroupName: first.name)], nextToken: "group-next"),
            .init(logGroups: [.init(logGroupArn: second.arn, logGroupName: second.name)])
        ])
        let rows = try await fixture.service.loadGroups(scope: logsVersionsScope())
        XCTAssertEqual(rows.map(\.name), ["/a", "/b"])
        let inputs = await fixture.groupInputs
        XCTAssertEqual(inputs.map(\.nextToken), [nil, "group-next"])
    }

    func testGroupsRejectCrossAccountRegionPartitionAndDisagreeingARNs() async {
        let group = logsBrowserGroup()
        for arn in [group.arn.replacingOccurrences(of: "111122223333", with: "444455556666"),
                    group.arn.replacingOccurrences(of: "eu-west-1", with: "us-east-1"),
                    group.arn.replacingOccurrences(of: "arn:aws:", with: "arn:aws-cn:")] {
            let fixture = LogsBrowserFixture(groups: [.init(logGroups: [.init(logGroupArn: arn, logGroupName: group.name)])])
            await assertError(.invalidResponse) { _ = try await fixture.service.loadGroups(scope: logsVersionsScope()) }
        }
        let fixture = LogsBrowserFixture(groups: [.init(logGroups: [.init(arn: group.arn + "other:*", logGroupArn: group.arn, logGroupName: group.name)])])
        await assertError(.invalidResponse) { _ = try await fixture.service.loadGroups(scope: logsVersionsScope()) }
    }

    func testInvalidScopeMakesNoRequest() async {
        let fixture = LogsBrowserFixture()
        await assertError(.invalidScope) { _ = try await fixture.service.loadGroups(scope: logsVersionsScope(account: "invalid")) }
        let count = await fixture.groupInputs.count
        XCTAssertEqual(count, 0)
    }

    func testRepeatedBlankAndDuplicateGroupPaginationAreRejected() async {
        let group = logsBrowserGroup()
        for token in ["next", " "] {
            let fixture = LogsBrowserFixture(groups: [.init(nextToken: token), .init(nextToken: token)])
            await assertError(.incompletePagination) { _ = try await fixture.service.loadGroups(scope: logsVersionsScope()) }
        }
        let fixture = LogsBrowserFixture(groups: [.init(logGroups: [
            .init(logGroupArn: group.arn, logGroupName: group.name), .init(logGroupArn: group.arn, logGroupName: group.name)
        ])])
        await assertError(.invalidResponse) { _ = try await fixture.service.loadGroups(scope: logsVersionsScope()) }
    }

    func testLaterGroupFailureCannotReturnPartialSuccessOrRawError() async {
        let fixture = LogsBrowserFixture(groups: [.init(nextToken: "next")], failAt: 1)
        await assertError(.permission) { _ = try await fixture.service.loadGroups(scope: logsVersionsScope()) }
        XCTAssertFalse(CloudWatchLogsBrowserError.permission.localizedDescription.contains("private-test-content"))
    }

    func testStreamsUseExactSelectedGroupAndPreserveUnknownTimestamps() async throws {
        let group = logsBrowserGroup()
        let fixture = LogsBrowserFixture(streams: [
            .init(logStreams: [.init(arn: group.arn + ":log-stream:app/main", logStreamName: "app/main")], nextToken: "stream-next"),
            .init(logStreams: [.init(logStreamName: "app/second")])
        ])
        let rows = try await fixture.service.loadStreams(scope: logsVersionsScope(), group: group)
        XCTAssertEqual(rows.map(\.name), ["app/main", "app/second"])
        XCTAssertNil(rows[0].lastEventAt)
        let inputs = await fixture.streamInputs
        XCTAssertEqual(inputs.map(\.logGroupName), [group.name, group.name])
        XCTAssertEqual(inputs.map(\.nextToken), [nil, "stream-next"])
        XCTAssertTrue(inputs.allSatisfy { $0.logGroupIdentifier == nil })
    }

    func testStreamsRejectForeignGroupAndForeignStreamARN() async {
        let group = logsBrowserGroup()
        let fixture = LogsBrowserFixture(streams: [.init(logStreams: [.init(arn: "arn:aws:logs:eu-west-1:444455556666:log-group:/foreign:log-stream:app", logStreamName: "app")])])
        await assertError(.invalidResponse) { _ = try await fixture.service.loadStreams(scope: logsVersionsScope(), group: group) }
        let foreign = logsBrowserGroup(scope: logsVersionsScope(account: "444455556666"))
        await assertError(.invalidScope) { _ = try await fixture.service.loadStreams(scope: logsVersionsScope(), group: foreign) }
    }

    func testEventsAreOneManualPageWithExactRangeStreamFilterAndMaskedData() async throws {
        let query = logsBrowserQuery(stream: "app/main", pattern: "ERROR")
        let fixture = LogsBrowserFixture(events: [.init(events: [.init(eventId: "event", ingestionTime: query.endMilliseconds,
            logStreamName: "app/main", message: "error text", timestamp: query.startMilliseconds)], nextToken: "next")])
        let page = try await fixture.service.loadEvents(query: query, cursor: nil)
        XCTAssertEqual(page.events.map(\.id), ["event"])
        XCTAssertEqual(page.cursor?.query, query)
        let inputs = await fixture.eventInputs
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].logGroupName, query.group.name)
        XCTAssertEqual(inputs[0].logStreamNames, ["app/main"])
        XCTAssertEqual(inputs[0].startTime, query.startMilliseconds)
        XCTAssertEqual(inputs[0].endTime, query.endMilliseconds)
        XCTAssertEqual(inputs[0].filterPattern, "ERROR")
        XCTAssertEqual(inputs[0].unmask, false)
        XCTAssertEqual(inputs[0].limit, 500)
    }

    func testEmptyEventPageMayContinueWithBoundCursor() async throws {
        let fixture = LogsBrowserFixture(events: [.init(nextToken: "next"), .init()])
        let query = logsBrowserQuery()
        let first = try await fixture.service.loadEvents(query: query, cursor: nil)
        XCTAssertTrue(first.events.isEmpty)
        let second = try await fixture.service.loadEvents(query: query, cursor: try XCTUnwrap(first.cursor))
        XCTAssertNil(second.cursor)
        let inputs = await fixture.eventInputs
        XCTAssertEqual(inputs.map(\.nextToken), [nil, "next"])
    }

    func testCursorCannotBeReusedForOtherScopeStreamRangeOrFilter() async throws {
        let fixture = LogsBrowserFixture(events: [.init(nextToken: "next")])
        let query = logsBrowserQuery()
        let first = try await fixture.service.loadEvents(query: query, cursor: nil)
        for other in [logsBrowserQuery(scope: logsVersionsScope(profile: "other")), logsBrowserQuery(stream: "app/main"),
                      logsBrowserQuery(pattern: "ERROR"), .init(scope: query.scope, group: query.group, streamName: nil,
                        startTime: query.startTime, endTime: query.endTime.addingTimeInterval(1), filterPattern: "")] {
            await assertError(.invalidCursor) { _ = try await fixture.service.loadEvents(query: other, cursor: first.cursor) }
        }
        let count = await fixture.eventInputs.count
        XCTAssertEqual(count, 1)
    }

    func testRepeatedEventTokenAndOutOfRangeOrWrongStreamAreRejected() async throws {
        let fixture = LogsBrowserFixture(events: [.init(nextToken: "next"), .init(nextToken: "next")])
        let query = logsBrowserQuery(stream: "app")
        let first = try await fixture.service.loadEvents(query: query, cursor: nil)
        await assertError(.incompletePagination) { _ = try await fixture.service.loadEvents(query: query, cursor: first.cursor) }
        for event in [CloudWatchLogs.FilteredLogEvent(eventId: "id", logStreamName: "app", timestamp: query.startMilliseconds - 1),
                      .init(eventId: "id", logStreamName: "other", timestamp: query.startMilliseconds)] {
            let invalid = LogsBrowserFixture(events: [.init(events: [event])])
            await assertError(.invalidResponse) { _ = try await invalid.service.loadEvents(query: query, cursor: nil) }
        }
    }

    func testInvalidRangeAndPatternAreRejectedBeforeRequests() async {
        let query = logsBrowserQuery()
        let fixture = LogsBrowserFixture()
        for bad in [CloudWatchLogsBrowserQuery(scope: query.scope, group: query.group, streamName: nil,
                        startTime: query.endTime, endTime: query.startTime, filterPattern: ""),
                    .init(scope: query.scope, group: query.group, streamName: nil, startTime: query.startTime,
                          endTime: query.endTime, filterPattern: String(repeating: "x", count: 1_025))] {
            await assertError(.invalidScope) { _ = try await fixture.service.loadEvents(query: bad, cursor: nil) }
        }
        let count = await fixture.eventInputs.count
        XCTAssertEqual(count, 0)
    }

    private func assertError(_ expected: CloudWatchLogsBrowserError, operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected rejection", file: file, line: line) }
        catch { XCTAssertEqual(error as? CloudWatchLogsBrowserError, expected, file: file, line: line) }
    }
}
