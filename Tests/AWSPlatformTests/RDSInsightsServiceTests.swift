import Foundation
import SotoRDS
import XCTest
@testable import AWSPlatform

final class RDSInsightsServiceTests: XCTestCase {
    func testEventsBindExactSourceKindIdentifierAndFrozenFourteenDayWindowAcrossPages() async throws {
        for kind in [RDSResourceKind.instance, .cluster] {
            let database = RDSInsightsFixture.database(kind)
            let fixture = RDSInsightsServiceFixture(events: [
                .init(events: [RDSInsightsFixture.event(database)], marker: "next"),
                .init(events: [RDSInsightsFixture.event(database, date: RDSInsightsFixture.now.addingTimeInterval(-120))])
            ])
            let result = try await fixture.service().loadEvents(scope: rdsServiceScope(), database: database)
            let calls = await fixture.requests()
            XCTAssertEqual(calls.events.map(\.marker), [nil, "next"])
            XCTAssertTrue(calls.events.allSatisfy {
                $0.sourceType == (kind == .instance ? .dbInstance : .dbCluster) &&
                $0.sourceIdentifier == database.identifier && $0.maxRecords == 100 && $0.duration == nil &&
                $0.startTime == result.start && $0.endTime == result.end
            })
            XCTAssertEqual(result.end.timeIntervalSince(result.start), 14 * 24 * 3_600)
            XCTAssertEqual(result.events.count, 2)
            XCTAssertEqual(result.events.first?.kind, kind)
            XCTAssertGreaterThan(try XCTUnwrap(result.events.first?.date), try XCTUnwrap(result.events.last?.date))
            XCTAssertEqual(calls.instances.count + calls.clusters.count, 0)
        }
    }

    func testMissingEventMetadataIsPreservedAndExactDuplicateEventsAreCollapsed() async throws {
        let event = RDS.Event(sourceIdentifier: "production", sourceType: .dbInstance)
        let fixture = RDSInsightsServiceFixture(events: [.init(events: [event], marker: "next"), .init(events: [event])])
        let result = try await fixture.service().loadEvents(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        XCTAssertEqual(result.events.count, 1)
        XCTAssertNil(result.events.first?.sourceARN)
        XCTAssertNil(result.events.first?.date)
        XCTAssertNil(result.events.first?.message)
        XCTAssertNil(result.events.first?.categories)
    }

    func testEmptyEventsAreSuccessfulEmptyResult() async throws {
        let result = try await RDSInsightsServiceFixture().service().loadEvents(
            scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        XCTAssertTrue(result.events.isEmpty)
    }

    func testEventIdentityAndDateMismatchesRejectEntireResponse() async {
        let database = RDSInsightsFixture.database()
        let invalid = [
            RDS.Event(sourceIdentifier: "another", sourceType: .dbInstance),
            .init(sourceIdentifier: "production", sourceType: .dbCluster),
            .init(sourceIdentifier: "production"), .init(sourceType: .dbInstance),
            RDSInsightsFixture.event(arn: "arn:aws:rds:eu-west-1:999988887777:db:production"),
            RDSInsightsFixture.event(date: RDSInsightsFixture.now.addingTimeInterval(1)),
            RDSInsightsFixture.event(date: RDSInsightsFixture.now.addingTimeInterval(-14 * 24 * 3_600 - 1)),
            RDSInsightsFixture.event(date: Date(timeIntervalSince1970: .nan))
        ]
        for event in invalid {
            let fixture = RDSInsightsServiceFixture(events: [.init(events: [RDSInsightsFixture.event(), event])])
            await expect(.invalidResponse) { try await fixture.service().loadEvents(scope: rdsServiceScope(), database: database) }
        }
    }

    func testInstanceSnapshotsUseOnlyInstanceAPIAndPreserveOptionalMetadata() async throws {
        let fixture = RDSInsightsServiceFixture(instances: [
            .init(dbSnapshots: [RDSInsightsFixture.snapshot("manual")], marker: "next"),
            .init(dbSnapshots: [RDSInsightsFixture.snapshot("rds:automatic", type: "automated")])
        ])
        let result = try await fixture.service().loadSnapshots(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        let calls = await fixture.requests()
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(calls.instances.map(\.marker), [nil, "next"])
        XCTAssertTrue(calls.instances.allSatisfy {
            $0.dbInstanceIdentifier == "production" && $0.includeShared == false && $0.includePublic == false &&
            $0.maxRecords == 100 && $0.snapshotType == nil
        })
        XCTAssertEqual(calls.clusters.count + calls.events.count, 0)
        XCTAssertNil(result.first?.encrypted)
        XCTAssertNil(result.first?.status)
        XCTAssertNil(result.first?.allocatedStorageGB)
    }

    func testClusterSnapshotsUseOnlyClusterAPIAndBindClusterRelationship() async throws {
        let fixture = RDSInsightsServiceFixture(clusters: [.init(dbClusterSnapshots: [RDSInsightsFixture.clusterSnapshot()])])
        let result = try await fixture.service().loadSnapshots(scope: rdsServiceScope(), database: RDSInsightsFixture.database(.cluster))
        let calls = await fixture.requests()
        let request = try XCTUnwrap(calls.clusters.first)
        XCTAssertEqual(request.dbClusterIdentifier, "production")
        XCTAssertEqual(request.includeShared, false)
        XCTAssertEqual(request.includePublic, false)
        XCTAssertEqual(request.maxRecords, 100)
        XCTAssertNil(request.snapshotType)
        XCTAssertEqual(calls.instances.count + calls.events.count, 0)
        XCTAssertEqual(result.first?.kind, .cluster)
        XCTAssertEqual(result.first?.encrypted, false)
    }

    func testSnapshotOwnershipRegionKindRelationshipAndPublicFlagsAreChecked() async {
        let invalid = [
            RDSInsightsFixture.snapshot(source: "another"),
            RDSInsightsFixture.snapshot(arn: "arn:aws:rds:eu-west-1:999988887777:snapshot:backup"),
            RDSInsightsFixture.snapshot(arn: "arn:aws:rds:us-east-1:111122223333:snapshot:backup"),
            RDSInsightsFixture.snapshot(arn: "arn:aws-cn:rds:eu-west-1:111122223333:snapshot:backup"),
            RDSInsightsFixture.snapshot(arn: "arn:aws:rds:eu-west-1:111122223333:cluster-snapshot:backup"),
            RDSInsightsFixture.snapshot(type: "shared"), RDSInsightsFixture.snapshot(type: "public"),
            RDSInsightsFixture.snapshot("bad\n"), .init(dbInstanceIdentifier: "production"),
            .init(dbInstanceIdentifier: "production", dbSnapshotArn: "arn:aws:rds:eu-west-1:111122223333:snapshot:backup",
                  dbSnapshotIdentifier: "backup", snapshotCreateTime: Date(timeIntervalSince1970: .infinity))
        ]
        for snapshot in invalid {
            let fixture = RDSInsightsServiceFixture(instances: [.init(dbSnapshots: [snapshot])])
            await expect(.invalidResponse) {
                try await fixture.service().loadSnapshots(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
            }
        }
    }

    func testClusterSnapshotsRejectForeignOrUnrelatedRows() async {
        for snapshot in [RDSInsightsFixture.clusterSnapshot(source: "another"),
                         RDSInsightsFixture.clusterSnapshot(type: "public"),
                         RDSInsightsFixture.clusterSnapshot(arn: "arn:aws:rds:eu-west-1:999988887777:cluster-snapshot:backup")] {
            let fixture = RDSInsightsServiceFixture(clusters: [.init(dbClusterSnapshots: [snapshot])])
            await expect(.invalidResponse) {
                try await fixture.service().loadSnapshots(scope: rdsServiceScope(), database: RDSInsightsFixture.database(.cluster))
            }
        }
    }

    func testSnapshotDuplicatesAcrossPagesAreRejectedRatherThanRenderedTwice() async {
        let snapshot = RDSInsightsFixture.snapshot()
        let fixture = RDSInsightsServiceFixture(instances: [
            .init(dbSnapshots: [snapshot], marker: "next"), .init(dbSnapshots: [snapshot])
        ])
        await expect(.invalidResponse) {
            try await fixture.service().loadSnapshots(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        }
    }

    func testAllOperationsRejectRepeatedAndBlankMarkersAndExhaustedBudget() async {
        for markers in [["again", "again"], [" "], ["page-2", "page-3"]] {
            let fixture = RDSInsightsServiceFixture(
                events: markers.map { .init(marker: $0) },
                instances: markers.map { .init(marker: $0) }, clusters: markers.map { .init(marker: $0) })
            let service = fixture.service(maximumPages: 2)
            await expect(.incompletePagination) { try await service.loadEvents(scope: rdsServiceScope(), database: RDSInsightsFixture.database()) }
            await expect(.incompletePagination) { try await service.loadSnapshots(scope: rdsServiceScope(), database: RDSInsightsFixture.database()) }
            await expect(.incompletePagination) { try await service.loadSnapshots(scope: rdsServiceScope(), database: RDSInsightsFixture.database(.cluster)) }
        }
    }

    func testLaterPageFailureCannotReturnPartialSuccess() async {
        let eventFixture = RDSInsightsServiceFixture(events: [.init(events: [RDSInsightsFixture.event()], marker: "next")],
                                                     fail: .events, failAt: 1)
        await expect(.eventsPermission) {
            try await eventFixture.service().loadEvents(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        }
        let snapshotFixture = RDSInsightsServiceFixture(instances: [.init(dbSnapshots: [RDSInsightsFixture.snapshot()], marker: "next")],
                                                        fail: .instances, failAt: 1)
        await expect(.snapshotsPermission) {
            try await snapshotFixture.service().loadSnapshots(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        }
        let clusterFixture = RDSInsightsServiceFixture(clusters: [.init(dbClusterSnapshots: [RDSInsightsFixture.clusterSnapshot()], marker: "next")],
                                                       fail: .clusters, failAt: 1)
        await expect(.snapshotsPermission) {
            try await clusterFixture.service().loadSnapshots(scope: rdsServiceScope(), database: RDSInsightsFixture.database(.cluster))
        }
    }

    func testInvalidScopeOrDatabaseNeverCallsAWS() async {
        let fixture = RDSInsightsServiceFixture()
        for (scope, database) in [
            (rdsServiceScope(account: "bad"), RDSInsightsFixture.database()),
            (rdsServiceScope(), RDSInsightsFixture.database(account: "999988887777")),
            (rdsServiceScope(), RDSInsightsFixture.database(region: "us-east-1")),
            (rdsServiceScope(), RDSInsightsFixture.database(identifier: "bad--name")),
            (rdsServiceScope(), RDSInsightsFixture.database(identifier: "bad\n"))
        ] {
            await expect(.invalidScope) { try await fixture.service().loadEvents(scope: scope, database: database) }
            await expect(.invalidScope) { try await fixture.service().loadSnapshots(scope: scope, database: database) }
        }
        let requests = await fixture.requests()
        XCTAssertEqual(requests.total, 0)
    }

    func testErrorsUseFixedSafeMessagesWithoutRawProviderData() async {
        for (failure, expected) in [
            (RDSFixtureError("ThrottlingException"), RDSInsightsError.throttled),
            (RDSFixtureError("InvalidMarker"), .incompletePagination),
            (RDSFixtureError("ExpiredTokenException"), .credentials),
            (RDSFixtureError("UnknownFailure"), .failed)
        ] {
            let fixture = RDSInsightsServiceFixture(fail: .events, error: failure)
            await expect(expected) {
                try await fixture.service().loadEvents(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
            }
            XCTAssertFalse(AWSRDSInsightsService.safeMessage(failure).contains("private"))
        }
    }

    func testCancellationIsPreservedAndNoRequestsStart() async {
        let fixture = RDSInsightsServiceFixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.service().loadEvents(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await fixture.requests()
        XCTAssertEqual(requests.total, 0)
    }

    private func expect<Value>(_ expected: RDSInsightsError, operation: () async throws -> Value) async {
        do { _ = try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? RDSInsightsError, expected) }
    }
}
