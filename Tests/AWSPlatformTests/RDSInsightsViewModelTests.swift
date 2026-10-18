import Foundation
import XCTest
@testable import AWSPlatform

@MainActor
final class RDSInsightsViewModelTests: XCTestCase {
    func testNoSelectionOrUnverifiedScopeCannotStartRequests() async {
        let probe = RDSInsightsViewModelProbe()
        let vm = model(probe)
        let cases: [(MonitoringScope?, RDSDatabase?)] = [(nil, nil), (rdsServiceScope(), nil),
                                  (rdsServiceScope(account: "bad"), RDSInsightsFixture.database()),
                                  (rdsServiceScope(), RDSInsightsFixture.database(account: "999988887777"))]
        for (scope, database) in cases {
            vm.configure(scope: scope, database: database)
            vm.loadEvents()
            vm.loadSnapshots()
            await vm.waitForLoading()
            XCTAssertNil(vm.scope)
            XCTAssertNil(vm.database)
        }
        let calls = await probe.counts()
        XCTAssertEqual(calls.events + calls.snapshots, 0)
    }

    func testConfigureAndRepeatedConfigureNeverAutomaticallyLoad() async {
        let probe = RDSInsightsViewModelProbe()
        let vm = model(probe)
        vm.configure(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        vm.configure(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        await vm.waitForLoading()
        let calls = await probe.counts()
        XCTAssertEqual(calls.events + calls.snapshots, 0)
        XCTAssertNil(vm.eventsSnapshot)
        XCTAssertFalse(vm.hasLoadedSnapshots)
    }

    func testEventsAndSnapshotsLoadIndependentlyAndUnknownFieldsRemainUnknown() async {
        let gate = RDSServiceRequestGate()
        let vm = model(RDSInsightsViewModelProbe(gate: gate))
        vm.configure(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        vm.loadEvents()
        await gate.waitForEntry()
        vm.loadSnapshots()
        for _ in 0..<100 where vm.isSnapshotsLoading { await Task.yield() }
        XCTAssertTrue(vm.isEventsLoading)
        XCTAssertTrue(vm.hasLoadedSnapshots)
        XCTAssertNil(vm.snapshots.first?.encrypted)
        XCTAssertNil(vm.snapshots.first?.createdAt)
        XCTAssertNil(vm.snapshots.first?.allocatedStorageGB)
        await gate.open()
        await vm.waitForLoading()
        XCTAssertEqual(vm.eventsSnapshot?.events.count, 1)
        XCTAssertFalse(vm.isEventsLoading)
        XCTAssertNil(vm.eventsError)
    }

    func testEmptyResponsesAreDistinctFromNotLoaded() async {
        let vm = RDSInsightsViewModel(eventsLoader: { _, db in
            .init(databaseARN: db.arn, start: RDSInsightsFixture.now.addingTimeInterval(-14 * 24 * 3_600),
                  end: RDSInsightsFixture.now, events: [])
        }, snapshotsLoader: { _, _ in [] })
        vm.configure(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        XCTAssertNil(vm.eventsSnapshot)
        XCTAssertFalse(vm.hasLoadedSnapshots)
        vm.loadEvents()
        vm.loadSnapshots()
        await vm.waitForLoading()
        XCTAssertEqual(vm.eventsSnapshot?.events, [])
        XCTAssertTrue(vm.hasLoadedSnapshots)
        XCTAssertTrue(vm.snapshots.isEmpty)
    }

    func testPermissionFailureOfOneOperationPreservesOtherSuccessfulResult() async {
        let vm = RDSInsightsViewModel(eventsLoader: { _, _ in throw RDSInsightsError.eventsPermission },
                                      snapshotsLoader: { _, db in RDSInsightsFixture.snapshotsResult(db) })
        vm.configure(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        vm.loadEvents()
        vm.loadSnapshots()
        await vm.waitForLoading()
        XCTAssertEqual(vm.eventsError, RDSInsightsError.eventsPermission.localizedDescription)
        XCTAssertNil(vm.eventsSnapshot)
        XCTAssertTrue(vm.hasLoadedSnapshots)
        XCTAssertEqual(vm.snapshots.count, 1)
        XCTAssertNil(vm.snapshotsError)
    }

    func testProfileRegionRoleAndPathsChangesClearResultsAndRejectLateSuccessOrFailure() async {
        let changedRole = MonitoringScope(profile: rdsServiceScope().profile,
            identity: AWSIdentity(account: "111122223333", arn: "arn:aws:sts::111122223333:assumed-role/Other/session", userID: "test"),
            region: "eu-west-1", paths: rdsServiceScope().paths)
        let changedPaths = MonitoringScope(profile: rdsServiceScope().profile,
            identity: AWSIdentity(account: "111122223333", arn: rdsServiceScope().principalARN, userID: "test"),
            region: "eu-west-1", paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/other/config", "AWS_SHARED_CREDENTIALS_FILE": "/other/credentials"]))
        let scopes = [rdsServiceScope(profile: "another"), rdsServiceScope(region: "us-east-1"), changedRole, changedPaths]
        for fail in [false, true] {
            for nextScope in scopes {
                let gate = RDSServiceRequestGate()
                let vm = model(RDSInsightsViewModelProbe(gate: gate, failFirst: fail))
                vm.configure(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
                vm.loadEvents()
                await gate.waitForEntry()
                let oldWaiter = Task { await vm.waitForLoading() }
                await Task.yield()
                let database = RDSInsightsFixture.database(region: nextScope.region)
                vm.configure(scope: nextScope, database: database)
                XCTAssertNil(vm.eventsSnapshot)
                XCTAssertTrue(vm.snapshots.isEmpty)
                XCTAssertFalse(vm.hasLoadedSnapshots)
                await gate.open()
                await oldWaiter.value
                XCTAssertEqual(vm.scope, nextScope)
                XCTAssertEqual(vm.database, database)
                XCTAssertNil(vm.eventsSnapshot)
                XCTAssertNil(vm.eventsError)
                XCTAssertFalse(vm.isEventsLoading)
            }
        }
    }

    func testChangingDatabaseOrKindRejectsLateCallbacksAndAllowsFreshLoad() async {
        for next in [RDSInsightsFixture.database(identifier: "another"), RDSInsightsFixture.database(.cluster)] {
            let gate = RDSServiceRequestGate()
            let vm = model(RDSInsightsViewModelProbe(gate: gate))
            vm.configure(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
            vm.loadEvents()
            await gate.waitForEntry()
            let oldWaiter = Task { await vm.waitForLoading() }
            await Task.yield()
            vm.configure(scope: rdsServiceScope(), database: next)
            vm.loadEvents()
            await vm.waitForLoading()
            await gate.open()
            await oldWaiter.value
            XCTAssertEqual(vm.eventsSnapshot?.databaseARN, next.arn)
            XCTAssertEqual(vm.eventsSnapshot?.events.first?.kind, next.kind)
            XCTAssertNil(vm.eventsError)
        }
    }

    func testResetAndClearSelectionInvalidatePendingResponses() async {
        for clear in [false, true] {
            let gate = RDSServiceRequestGate()
            let vm = model(RDSInsightsViewModelProbe(gate: gate))
            vm.configure(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
            vm.loadEvents()
            await gate.waitForEntry()
            let waiter = Task { await vm.waitForLoading() }
            await Task.yield()
            if clear { vm.configure(scope: nil, database: nil) } else { vm.reset() }
            await gate.open()
            await waiter.value
            XCTAssertNil(vm.scope)
            XCTAssertNil(vm.database)
            XCTAssertNil(vm.eventsSnapshot)
            XCTAssertNil(vm.eventsError)
        }
    }

    func testCancelKeepsOtherResultAndContextThenManualRetryWins() async {
        let gate = RDSServiceRequestGate()
        let vm = model(RDSInsightsViewModelProbe(gate: gate))
        vm.configure(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        vm.loadSnapshots()
        await vm.waitForLoading()
        vm.loadEvents()
        await gate.waitForEntry()
        let waiter = Task { await vm.waitForLoading() }
        await Task.yield()
        vm.cancelEvents()
        XCTAssertFalse(vm.isEventsLoading)
        XCTAssertTrue(vm.hasLoadedSnapshots)
        XCTAssertEqual(vm.snapshots.count, 1)
        XCTAssertNotNil(vm.eventsError)
        vm.loadEvents()
        await vm.waitForLoading()
        await gate.open()
        await waiter.value
        XCTAssertNotNil(vm.eventsSnapshot)
        XCTAssertNil(vm.eventsError)
        XCTAssertEqual(vm.database, RDSInsightsFixture.database())
    }

    func testSnapshotsRejectLateSuccessAndFailureAfterResourceChangeOrCancellation() async {
        for fail in [false, true] {
            for cancel in [false, true] {
                let gate = RDSServiceRequestGate()
                let vm = model(RDSInsightsViewModelProbe(snapshotGate: gate, failFirstSnapshot: fail))
                let first = RDSInsightsFixture.database()
                let next = cancel ? first : RDSInsightsFixture.database(identifier: "another")
                vm.configure(scope: rdsServiceScope(), database: first)
                vm.loadSnapshots()
                await gate.waitForEntry()
                let waiter = Task { await vm.waitForLoading() }
                await Task.yield()
                if cancel { vm.cancelSnapshots() } else { vm.configure(scope: rdsServiceScope(), database: next) }
                vm.loadSnapshots()
                await vm.waitForLoading()
                await gate.open()
                await waiter.value
                XCTAssertEqual(vm.snapshots.first?.databaseIdentifier, next.identifier)
                XCTAssertNil(vm.snapshotsError)
                XCTAssertTrue(vm.hasLoadedSnapshots)
                XCTAssertFalse(vm.isSnapshotsLoading)
            }
        }
    }

    func testLoadingGuardsRejectDuplicateClicksWithoutCancellingOtherOperation() async {
        let eventGate = RDSServiceRequestGate()
        let snapshotGate = RDSServiceRequestGate()
        let probe = RDSInsightsViewModelProbe(gate: eventGate, snapshotGate: snapshotGate)
        let vm = model(probe)
        vm.configure(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        vm.loadEvents()
        vm.loadEvents()
        vm.loadSnapshots()
        vm.loadSnapshots()
        await eventGate.waitForEntry()
        await snapshotGate.waitForEntry()
        let calls = await probe.counts()
        XCTAssertEqual(calls.events, 1)
        XCTAssertEqual(calls.snapshots, 1)
        await eventGate.open()
        await snapshotGate.open()
        await vm.waitForLoading()
        XCTAssertNotNil(vm.eventsSnapshot)
        XCTAssertTrue(vm.hasLoadedSnapshots)
    }

    func testInjectedResultsWithWrongDatabaseWindowSourceOrOwnershipAreRejected() async {
        let db = RDSInsightsFixture.database()
        let valid = RDSInsightsFixture.eventsResult()
        let invalidEvents = [
            RDSInsightsFixture.eventsResult(RDSInsightsFixture.database(identifier: "another")),
            RDSEventsSnapshot(databaseARN: db.arn, start: valid.start, end: valid.end.addingTimeInterval(1), events: []),
            RDSEventsSnapshot(databaseARN: db.arn, start: valid.start, end: valid.end,
                              events: RDSInsightsFixture.eventsResult(RDSInsightsFixture.database(.cluster)).events)
        ]
        for invalid in invalidEvents {
            let vm = RDSInsightsViewModel(eventsLoader: { _, _ in invalid }, snapshotsLoader: { _, _ in [] })
            vm.configure(scope: rdsServiceScope(), database: db)
            vm.loadEvents()
            await vm.waitForLoading()
            XCTAssertNil(vm.eventsSnapshot)
            XCTAssertEqual(vm.eventsError, RDSInsightsError.invalidResponse.localizedDescription)
        }
        for invalid in [RDSInsightsFixture.snapshotsResult(RDSInsightsFixture.database(account: "999988887777")),
                        RDSInsightsFixture.snapshotsResult(RDSInsightsFixture.database(.cluster)),
                        RDSInsightsFixture.snapshotsResult(RDSInsightsFixture.database(identifier: "another"))] {
            let vm = RDSInsightsViewModel(eventsLoader: { _, _ in valid }, snapshotsLoader: { _, _ in invalid })
            vm.configure(scope: rdsServiceScope(), database: db)
            vm.loadSnapshots()
            await vm.waitForLoading()
            XCTAssertTrue(vm.snapshots.isEmpty)
            XCTAssertFalse(vm.hasLoadedSnapshots)
            XCTAssertEqual(vm.snapshotsError, RDSInsightsError.invalidResponse.localizedDescription)
        }
    }

    func testRawInjectedErrorsAreSanitized() async {
        let vm = RDSInsightsViewModel(eventsLoader: { _, _ in throw RDSFixtureError("private-request") },
                                      snapshotsLoader: { _, _ in throw NSError(domain: "private-endpoint", code: 1) })
        vm.configure(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        vm.loadEvents()
        vm.loadSnapshots()
        await vm.waitForLoading()
        XCTAssertEqual(vm.eventsError, RDSInsightsError.failed.localizedDescription)
        XCTAssertEqual(vm.snapshotsError, RDSInsightsError.failed.localizedDescription)
        XCTAssertFalse((vm.eventsError ?? "").contains("private"))
        XCTAssertFalse(vm.hasLoadedSnapshots)
    }

    func testReloadFailureClearsOldSuccessfulResults() async {
        let probe = RDSInsightsReloadProbe()
        let vm = RDSInsightsViewModel(eventsLoader: { _, db in try await probe.events(db) },
                                      snapshotsLoader: { _, db in try await probe.snapshots(db) })
        vm.configure(scope: rdsServiceScope(), database: RDSInsightsFixture.database())
        vm.loadEvents()
        vm.loadSnapshots()
        await vm.waitForLoading()
        XCTAssertNotNil(vm.eventsSnapshot)
        XCTAssertTrue(vm.hasLoadedSnapshots)
        vm.loadEvents()
        vm.loadSnapshots()
        XCTAssertNil(vm.eventsSnapshot)
        XCTAssertTrue(vm.snapshots.isEmpty)
        XCTAssertFalse(vm.hasLoadedSnapshots)
        await vm.waitForLoading()
        XCTAssertEqual(vm.eventsError, RDSInsightsError.failed.localizedDescription)
        XCTAssertEqual(vm.snapshotsError, RDSInsightsError.failed.localizedDescription)
    }

    private func model(_ probe: RDSInsightsViewModelProbe) -> RDSInsightsViewModel {
        RDSInsightsViewModel(eventsLoader: { try await probe.events(scope: $0, database: $1) },
                             snapshotsLoader: { try await probe.snapshots(scope: $0, database: $1) })
    }
}

private actor RDSInsightsReloadProbe {
    private var eventsCount = 0
    private var snapshotsCount = 0
    func events(_ database: RDSDatabase) throws -> RDSEventsSnapshot {
        eventsCount += 1
        if eventsCount > 1 { throw RDSFixtureError("private-refresh-failure") }
        return RDSInsightsFixture.eventsResult(database)
    }
    func snapshots(_ database: RDSDatabase) throws -> [RDSDatabaseSnapshot] {
        snapshotsCount += 1
        if snapshotsCount > 1 { throw RDSFixtureError("private-refresh-failure") }
        return RDSInsightsFixture.snapshotsResult(database)
    }
}
