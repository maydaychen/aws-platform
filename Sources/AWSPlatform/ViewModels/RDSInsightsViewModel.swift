import Foundation

@MainActor
final class RDSInsightsViewModel: ObservableObject {
    typealias EventsLoader = @Sendable (MonitoringScope, RDSDatabase) async throws -> RDSEventsSnapshot
    typealias SnapshotsLoader = @Sendable (MonitoringScope, RDSDatabase) async throws -> [RDSDatabaseSnapshot]

    @Published private(set) var scope: MonitoringScope?
    @Published private(set) var database: RDSDatabase?
    @Published private(set) var eventsSnapshot: RDSEventsSnapshot?
    @Published private(set) var snapshots: [RDSDatabaseSnapshot] = []
    @Published private(set) var hasLoadedSnapshots = false
    @Published private(set) var isEventsLoading = false
    @Published private(set) var isSnapshotsLoading = false
    @Published private(set) var eventsError: String?
    @Published private(set) var snapshotsError: String?

    private let eventsLoader: EventsLoader
    private let snapshotsLoader: SnapshotsLoader
    private var eventsTask: Task<Void, Never>?
    private var snapshotsTask: Task<Void, Never>?
    private var eventsGeneration = 0
    private var snapshotsGeneration = 0

    convenience init(provider: AWSServiceProvider) {
        let service = AWSRDSInsightsService(provider: provider)
        self.init(eventsLoader: { try await service.loadEvents(scope: $0, database: $1) },
                  snapshotsLoader: { try await service.loadSnapshots(scope: $0, database: $1) })
    }

    init(eventsLoader: @escaping EventsLoader, snapshotsLoader: @escaping SnapshotsLoader) {
        self.eventsLoader = eventsLoader
        self.snapshotsLoader = snapshotsLoader
    }

    func configure(scope: MonitoringScope?, database: RDSDatabase?) {
        guard let scope, let database, (try? AWSRDSInsightsService.validate(scope: scope, database: database)) != nil else {
            reset()
            return
        }
        guard self.scope != scope || self.database != database else { return }
        reset()
        self.scope = scope
        self.database = database
    }

    func loadEvents() {
        guard !isEventsLoading, let scope, let database else { return }
        eventsGeneration += 1
        let generation = eventsGeneration
        eventsSnapshot = nil
        eventsError = nil
        isEventsLoading = true
        let loader = eventsLoader
        eventsTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await loader(scope, database)
                try Task.checkCancellation()
                guard let self, self.isCurrent(scope, database), self.eventsGeneration == generation else { return }
                try self.validate(result, database: database)
                self.eventsSnapshot = result
                self.isEventsLoading = false
                self.eventsTask = nil
            } catch {
                guard let self, self.isCurrent(scope, database), self.eventsGeneration == generation else { return }
                self.isEventsLoading = false
                self.eventsTask = nil
                if !Task.isCancelled { self.eventsError = AWSRDSInsightsService.safeMessage(error) }
            }
        }
    }

    func loadSnapshots() {
        guard !isSnapshotsLoading, let scope, let database else { return }
        snapshotsGeneration += 1
        let generation = snapshotsGeneration
        snapshots = []
        hasLoadedSnapshots = false
        snapshotsError = nil
        isSnapshotsLoading = true
        let loader = snapshotsLoader
        snapshotsTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await loader(scope, database)
                try Task.checkCancellation()
                guard let self, self.isCurrent(scope, database), self.snapshotsGeneration == generation else { return }
                try self.validate(result, scope: scope, database: database)
                self.snapshots = result
                self.hasLoadedSnapshots = true
                self.isSnapshotsLoading = false
                self.snapshotsTask = nil
            } catch {
                guard let self, self.isCurrent(scope, database), self.snapshotsGeneration == generation else { return }
                self.isSnapshotsLoading = false
                self.snapshotsTask = nil
                if !Task.isCancelled { self.snapshotsError = AWSRDSInsightsService.safeMessage(error) }
            }
        }
    }

    func cancelEvents() {
        eventsGeneration += 1
        eventsTask?.cancel()
        eventsTask = nil
        isEventsLoading = false
        eventsError = "Loading cancelled. Use Refresh to try again."
    }

    func cancelSnapshots() {
        snapshotsGeneration += 1
        snapshotsTask?.cancel()
        snapshotsTask = nil
        isSnapshotsLoading = false
        snapshotsError = "Loading cancelled. Use Refresh to try again."
    }

    func reset() {
        eventsGeneration += 1
        snapshotsGeneration += 1
        eventsTask?.cancel()
        snapshotsTask?.cancel()
        eventsTask = nil
        snapshotsTask = nil
        scope = nil
        database = nil
        eventsSnapshot = nil
        snapshots = []
        hasLoadedSnapshots = false
        isEventsLoading = false
        isSnapshotsLoading = false
        eventsError = nil
        snapshotsError = nil
    }

    func waitForLoading() async {
        let events = eventsTask
        let snapshots = snapshotsTask
        await events?.value
        await snapshots?.value
    }

    private func isCurrent(_ scope: MonitoringScope, _ database: RDSDatabase) -> Bool {
        self.scope == scope && self.database == database
    }

    private func validate(_ result: RDSEventsSnapshot, database: RDSDatabase) throws {
        guard result.databaseARN == database.arn,
              result.start.timeIntervalSince1970.isFinite, result.end.timeIntervalSince1970.isFinite,
              abs(result.end.timeIntervalSince(result.start) - 14 * 24 * 3_600) < 0.001,
              Set(result.events).count == result.events.count,
              result.events.allSatisfy({
                  $0.kind == database.kind && $0.sourceIdentifier == database.identifier &&
                  ($0.sourceARN == nil || $0.sourceARN == database.arn) &&
                  ($0.date.map { $0.timeIntervalSince1970.isFinite && $0 >= result.start && $0 <= result.end } ?? true)
              }) else { throw RDSInsightsError.invalidResponse }
    }

    private func validate(_ rows: [RDSDatabaseSnapshot], scope: MonitoringScope, database: RDSDatabase) throws {
        let partition = scope.principalARN.split(separator: ":", omittingEmptySubsequences: false)[1]
        let resource = database.kind == .instance ? "snapshot" : "cluster-snapshot"
        guard Set(rows.map(\.arn)).count == rows.count, rows.allSatisfy({ row in
            !row.identifier.isEmpty && row.kind == database.kind && row.databaseIdentifier == database.identifier &&
            row.arn == "arn:\(partition):rds:\(scope.region):\(scope.accountID):\(resource):\(row.identifier)" &&
            !["shared", "public"].contains(row.type?.lowercased() ?? "") &&
            (row.createdAt?.timeIntervalSince1970.isFinite ?? true)
        }) else { throw RDSInsightsError.invalidResponse }
    }
}
