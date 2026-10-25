import Foundation
import SotoCore
import SotoRDS

struct AWSRDSInsightsService: Sendable {
    typealias EventsLoader = @Sendable (RDS.DescribeEventsMessage) async throws -> RDS.EventsMessage
    typealias SnapshotsLoader = @Sendable (RDS.DescribeDBSnapshotsMessage) async throws -> RDS.DBSnapshotMessage
    typealias ClusterSnapshotsLoader = @Sendable (RDS.DescribeDBClusterSnapshotsMessage) async throws -> RDS.DBClusterSnapshotMessage

    private struct Operations: Sendable {
        let events: EventsLoader
        let instances: SnapshotsLoader
        let clusters: ClusterSnapshotsLoader
    }

    private let provider: AWSServiceProvider?
    private let injected: Operations?
    private let now: @Sendable () -> Date
    private let maximumPages: Int

    init(provider: AWSServiceProvider) {
        self.provider = provider
        injected = nil
        now = { Date() }
        maximumPages = 1_000
    }

    init(eventsLoader: @escaping EventsLoader, snapshotsLoader: @escaping SnapshotsLoader,
         clusterSnapshotsLoader: @escaping ClusterSnapshotsLoader,
         maximumPages: Int = 1_000, now: @escaping @Sendable () -> Date = { Date() }) {
        provider = nil
        injected = Operations(events: eventsLoader, instances: snapshotsLoader, clusters: clusterSnapshotsLoader)
        self.maximumPages = min(maximumPages, 1_000)
        self.now = now
    }

    func loadEvents(scope: MonitoringScope, database: RDSDatabase) async throws -> RDSEventsSnapshot {
        do {
            let operations = try await operations(scope: scope, database: database)
            let end = now()
            guard end.timeIntervalSince1970.isFinite else { throw RDSInsightsError.invalidScope }
            let start = end.addingTimeInterval(-14 * 24 * 3_600)
            let sourceType: RDS.SourceType = database.kind == .instance ? .dbInstance : .dbCluster
            let events: [RDSDatabaseEvent] = try await pages { marker in
                let response = try await operations.events(.init(
                    endTime: end, marker: marker, maxRecords: 100,
                    sourceIdentifier: database.identifier, sourceType: sourceType, startTime: start
                ))
                let rows = try (response.events ?? []).map { raw -> RDSDatabaseEvent in
                    guard raw.sourceIdentifier == database.identifier, raw.sourceType == sourceType,
                          raw.sourceArn == nil || raw.sourceArn == database.arn,
                          raw.date.map({ $0.timeIntervalSince1970.isFinite && $0 >= start && $0 <= end }) ?? true else {
                        throw RDSInsightsError.invalidResponse
                    }
                    return RDSDatabaseEvent(sourceARN: raw.sourceArn, sourceIdentifier: database.identifier,
                                            kind: database.kind, date: raw.date,
                                            categories: raw.eventCategories, message: raw.message)
                }
                return (rows, response.marker)
            }
            var seen: Set<RDSDatabaseEvent> = []
            let unique = events.filter { seen.insert($0).inserted }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return RDSEventsSnapshot(databaseARN: database.arn, start: start, end: end, events: unique)
        } catch { throw Self.sanitized(error, events: true) }
    }

    func loadSnapshots(scope: MonitoringScope, database: RDSDatabase) async throws -> [RDSDatabaseSnapshot] {
        do {
            let operations = try await operations(scope: scope, database: database)
            let values: [RDSDatabaseSnapshot]
            switch database.kind {
            case .instance:
                values = try await pages { marker in
                    let response = try await operations.instances(.init(
                        dbInstanceIdentifier: database.identifier, includePublic: false,
                        includeShared: false, marker: marker, maxRecords: 100
                    ))
                    return (try (response.dbSnapshots ?? []).map { try Self.snapshot($0, scope: scope, database: database) }, response.marker)
                }
            case .cluster:
                values = try await pages { marker in
                    let response = try await operations.clusters(.init(
                        dbClusterIdentifier: database.identifier, includePublic: false,
                        includeShared: false, marker: marker, maxRecords: 100
                    ))
                    return (try (response.dbClusterSnapshots ?? []).map { try Self.snapshot($0, scope: scope, database: database) }, response.marker)
                }
            }
            guard Set(values.map(\.arn)).count == values.count else { throw RDSInsightsError.invalidResponse }
            return values.sorted {
                if $0.createdAt == $1.createdAt { return $0.identifier < $1.identifier }
                return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
        } catch { throw Self.sanitized(error, events: false) }
    }

    static func validate(scope: MonitoringScope, database: RDSDatabase) throws {
        guard scope.isValid, !scope.configPath.isEmpty, !scope.credentialsPath.isEmpty,
              database.identifier.range(of: "^[A-Za-z][A-Za-z0-9-]{0,62}$", options: .regularExpression) != nil,
              !database.identifier.hasSuffix("-"), !database.identifier.contains("--") else {
            throw RDSInsightsError.invalidScope
        }
        let resource = database.kind == .instance ? "db" : "cluster"
        let partition = scope.principalARN.split(separator: ":", omittingEmptySubsequences: false)[1]
        guard database.arn == "arn:\(partition):rds:\(scope.region):\(scope.accountID):\(resource):\(database.identifier)" else {
            throw RDSInsightsError.invalidScope
        }
    }

    private func operations(scope: MonitoringScope, database: RDSDatabase) async throws -> Operations {
        try Task.checkCancellation()
        try Self.validate(scope: scope, database: database)
        guard maximumPages > 0 else { throw RDSInsightsError.invalidScope }
        if let injected { return injected }
        guard let provider else { throw RDSInsightsError.invalidScope }
        let client = try await provider.rdsClient(scope: scope)
        return Operations(events: { try await client.describeEvents($0) },
                          instances: { try await client.describeDBSnapshots($0) },
                          clusters: { try await client.describeDBClusterSnapshots($0) })
    }

    private func pages<Row: Sendable>(
        _ loader: @Sendable (String?) async throws -> ([Row], String?)
    ) async throws -> [Row] {
        var rows: [Row] = []
        var marker: String?
        var seenMarkers: Set<String> = []
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let (page, next) = try await loader(marker)
            try Task.checkCancellation()
            rows += page
            guard let next, !next.isEmpty else { return rows }
            guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seenMarkers.insert(next).inserted else { throw RDSInsightsError.incompletePagination }
            marker = next
        }
        throw RDSInsightsError.incompletePagination
    }

    private static func snapshot(_ raw: RDS.DBSnapshot, scope: MonitoringScope,
                                 database: RDSDatabase) throws -> RDSDatabaseSnapshot {
        let (arn, identifier) = try snapshotIdentity(arn: raw.dbSnapshotArn, identifier: raw.dbSnapshotIdentifier,
                                                   source: raw.dbInstanceIdentifier, type: raw.snapshotType,
                                                   scope: scope, database: database)
        try validateDate(raw.snapshotCreateTime)
        return RDSDatabaseSnapshot(arn: arn, identifier: identifier, databaseIdentifier: database.identifier,
                                   kind: .instance, type: raw.snapshotType, status: raw.status,
                                   createdAt: raw.snapshotCreateTime, engine: raw.engine, engineVersion: raw.engineVersion,
                                   allocatedStorageGB: raw.allocatedStorage, encrypted: raw.encrypted,
                                   kmsKeyID: raw.kmsKeyId, progress: raw.percentProgress)
    }

    private static func snapshot(_ raw: RDS.DBClusterSnapshot, scope: MonitoringScope,
                                 database: RDSDatabase) throws -> RDSDatabaseSnapshot {
        let (arn, identifier) = try snapshotIdentity(arn: raw.dbClusterSnapshotArn, identifier: raw.dbClusterSnapshotIdentifier,
                                                   source: raw.dbClusterIdentifier, type: raw.snapshotType,
                                                   scope: scope, database: database)
        try validateDate(raw.snapshotCreateTime)
        return RDSDatabaseSnapshot(arn: arn, identifier: identifier, databaseIdentifier: database.identifier,
                                   kind: .cluster, type: raw.snapshotType, status: raw.status,
                                   createdAt: raw.snapshotCreateTime, engine: raw.engine, engineVersion: raw.engineVersion,
                                   allocatedStorageGB: raw.allocatedStorage, encrypted: raw.storageEncrypted,
                                   kmsKeyID: raw.kmsKeyId, progress: raw.percentProgress)
    }

    private static func snapshotIdentity(arn: String?, identifier: String?, source: String?, type: String?,
                                         scope: MonitoringScope, database: RDSDatabase) throws -> (String, String) {
        guard let arn, let identifier, !identifier.isEmpty, source == database.identifier,
              !["shared", "public"].contains(type?.lowercased() ?? ""),
              !identifier.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
              }) else { throw RDSInsightsError.invalidResponse }
        let partition = scope.principalARN.split(separator: ":", omittingEmptySubsequences: false)[1]
        let resource = database.kind == .instance ? "snapshot" : "cluster-snapshot"
        guard arn == "arn:\(partition):rds:\(scope.region):\(scope.accountID):\(resource):\(identifier)" else {
            throw RDSInsightsError.invalidResponse
        }
        return (arn, identifier)
    }

    private static func validateDate(_ date: Date?) throws {
        guard date?.timeIntervalSince1970.isFinite ?? true else { throw RDSInsightsError.invalidResponse }
    }

    static func safeMessage(_ error: Error) -> String {
        (error as? RDSInsightsError ?? .failed).localizedDescription
    }

    private static func sanitized(_ error: Error, events: Bool) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? RDSInsightsError { return error }
        if error is AWSServiceError { return RDSInsightsError.invalidScope }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedException", "UnauthorizedOperation", "ForbiddenException"].contains(code) {
            return events ? RDSInsightsError.eventsPermission : RDSInsightsError.snapshotsPermission
        }
        if UserFacingError.requiresSSOLogin(error) { return RDSInsightsError.credentials }
        if error is URLError { return RDSInsightsError.network }
        if ["Throttling", "ThrottlingException", "TooManyRequestsException"].contains(code) { return RDSInsightsError.throttled }
        if ["InvalidMarker", "InvalidMarkerException", "InvalidPaginationToken"].contains(code) { return RDSInsightsError.incompletePagination }
        return RDSInsightsError.failed
    }
}
