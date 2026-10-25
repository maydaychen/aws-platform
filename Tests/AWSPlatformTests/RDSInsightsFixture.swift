import Foundation
import SotoRDS
@testable import AWSPlatform

enum RDSInsightsFixture {
    static let now = Date(timeIntervalSince1970: 1_780_000_000)

    static func database(_ kind: RDSResourceKind = .instance, identifier: String = "production",
                         account: String = "111122223333", region: String = "eu-west-1",
                         engine: String? = "postgres") -> RDSDatabase {
        let resource = kind == .instance ? "db" : "cluster"
        return RDSDatabase(arn: "arn:aws:rds:\(region):\(account):\(resource):\(identifier)",
                           identifier: identifier, kind: kind, engine: engine)
    }

    static func event(_ database: RDSDatabase = database(), date: Date? = now.addingTimeInterval(-60),
                      message: String? = "Database restarted", arn: String? = nil) -> RDS.Event {
        .init(date: date, eventCategories: ["availability"], message: message, sourceArn: arn ?? database.arn,
              sourceIdentifier: database.identifier, sourceType: database.kind == .instance ? .dbInstance : .dbCluster)
    }

    static func snapshot(_ identifier: String = "backup", source: String = "production",
                         arn: String? = nil, type: String? = "manual") -> RDS.DBSnapshot {
        .init(dbInstanceIdentifier: source, dbSnapshotArn: arn ?? "arn:aws:rds:eu-west-1:111122223333:snapshot:\(identifier)",
              dbSnapshotIdentifier: identifier, encrypted: nil, snapshotCreateTime: now, snapshotType: type)
    }

    static func clusterSnapshot(_ identifier: String = "backup", source: String = "production",
                                arn: String? = nil, type: String? = "automated") -> RDS.DBClusterSnapshot {
        .init(dbClusterIdentifier: source,
              dbClusterSnapshotArn: arn ?? "arn:aws:rds:eu-west-1:111122223333:cluster-snapshot:\(identifier)",
              dbClusterSnapshotIdentifier: identifier, snapshotCreateTime: now, snapshotType: type, storageEncrypted: false)
    }

    static func eventsResult(_ database: RDSDatabase = database(), message: String? = "Database restarted") -> RDSEventsSnapshot {
        .init(databaseARN: database.arn, start: now.addingTimeInterval(-14 * 24 * 3_600), end: now,
              events: [.init(sourceARN: database.arn, sourceIdentifier: database.identifier, kind: database.kind,
                             date: now.addingTimeInterval(-60), categories: ["availability"], message: message)])
    }

    static func snapshotsResult(_ database: RDSDatabase = database(), identifier: String = "backup") -> [RDSDatabaseSnapshot] {
        let resource = database.kind == .instance ? "snapshot" : "cluster-snapshot"
        let prefix = database.arn.split(separator: ":", omittingEmptySubsequences: false).prefix(5).joined(separator: ":")
        return [.init(arn: "\(prefix):\(resource):\(identifier)", identifier: identifier,
                      databaseIdentifier: database.identifier, kind: database.kind, type: "manual", status: "creating",
                      createdAt: nil, engine: database.engine, engineVersion: nil, allocatedStorageGB: nil,
                      encrypted: nil, kmsKeyID: nil, progress: nil)]
    }
}

actor RDSInsightsServiceFixture {
    enum Operation: Sendable { case events, instances, clusters }
    struct Requests: Sendable {
        var events: [RDS.DescribeEventsMessage] = []
        var instances: [RDS.DescribeDBSnapshotsMessage] = []
        var clusters: [RDS.DescribeDBClusterSnapshotsMessage] = []
        var total: Int { events.count + instances.count + clusters.count }
    }

    private var recorded = Requests()
    private let eventPages: [RDS.EventsMessage]
    private let instancePages: [RDS.DBSnapshotMessage]
    private let clusterPages: [RDS.DBClusterSnapshotMessage]
    private let fail: Operation?
    private let failAt: Int
    private let error: Error

    init(events: [RDS.EventsMessage] = [.init()], instances: [RDS.DBSnapshotMessage] = [.init()],
         clusters: [RDS.DBClusterSnapshotMessage] = [.init()], fail: Operation? = nil,
         failAt: Int = 0, error: Error = RDSFixtureError("AccessDeniedException")) {
        eventPages = events
        instancePages = instances
        clusterPages = clusters
        self.fail = fail
        self.failAt = failAt
        self.error = error
    }

    func requests() -> Requests { recorded }

    func events(_ input: RDS.DescribeEventsMessage) throws -> RDS.EventsMessage {
        let index = recorded.events.count
        recorded.events.append(input)
        if fail == .events && index == failAt { throw error }
        return eventPages.indices.contains(index) ? eventPages[index] : .init()
    }

    func instances(_ input: RDS.DescribeDBSnapshotsMessage) throws -> RDS.DBSnapshotMessage {
        let index = recorded.instances.count
        recorded.instances.append(input)
        if fail == .instances && index == failAt { throw error }
        return instancePages.indices.contains(index) ? instancePages[index] : .init()
    }

    func clusters(_ input: RDS.DescribeDBClusterSnapshotsMessage) throws -> RDS.DBClusterSnapshotMessage {
        let index = recorded.clusters.count
        recorded.clusters.append(input)
        if fail == .clusters && index == failAt { throw error }
        return clusterPages.indices.contains(index) ? clusterPages[index] : .init()
    }

    nonisolated func service(maximumPages: Int = 1_000) -> AWSRDSInsightsService {
        AWSRDSInsightsService(eventsLoader: { try await self.events($0) },
                              snapshotsLoader: { try await self.instances($0) },
                              clusterSnapshotsLoader: { try await self.clusters($0) },
                              maximumPages: maximumPages, now: { RDSInsightsFixture.now })
    }
}

actor RDSInsightsViewModelProbe {
    private let gate: RDSServiceRequestGate?
    private let snapshotGate: RDSServiceRequestGate?
    private let failFirst: Bool
    private let failFirstSnapshot: Bool
    private var eventsCount = 0
    private var snapshotsCount = 0

    init(gate: RDSServiceRequestGate? = nil, failFirst: Bool = false,
         snapshotGate: RDSServiceRequestGate? = nil, failFirstSnapshot: Bool = false) {
        self.gate = gate
        self.failFirst = failFirst
        self.snapshotGate = snapshotGate
        self.failFirstSnapshot = failFirstSnapshot
    }

    func events(scope: MonitoringScope, database: RDSDatabase) async throws -> RDSEventsSnapshot {
        eventsCount += 1
        let call = eventsCount
        if call == 1, let gate { await gate.enter() }
        if call == 1 && failFirst { throw RDSFixtureError("private-failure") }
        return RDSInsightsFixture.eventsResult(database)
    }

    func snapshots(scope: MonitoringScope, database: RDSDatabase) async throws -> [RDSDatabaseSnapshot] {
        snapshotsCount += 1
        let call = snapshotsCount
        if call == 1, let snapshotGate { await snapshotGate.enter() }
        if call == 1 && failFirstSnapshot { throw RDSFixtureError("private-snapshot-failure") }
        return RDSInsightsFixture.snapshotsResult(database)
    }

    func counts() -> (events: Int, snapshots: Int) { (eventsCount, snapshotsCount) }
}
