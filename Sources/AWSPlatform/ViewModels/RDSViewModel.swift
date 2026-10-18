import Foundation

@MainActor
final class RDSViewModel: ObservableObject {
    typealias Loader = @Sendable (MonitoringScope) async throws -> [RDSDatabase]

    @Published private(set) var scope: MonitoringScope?
    @Published private(set) var instances: [RDSDatabase] = []
    @Published private(set) var clusters: [RDSDatabase] = []
    @Published private(set) var isInstancesLoading = false
    @Published private(set) var isClustersLoading = false
    @Published private(set) var instanceError: String?
    @Published private(set) var clusterError: String?
    @Published var searchText = ""
    @Published var kindFilter: RDSResourceKind?
    @Published var selectedDatabase: RDSDatabase? {
        didSet {
            guard !restoringSelection else { return }
            pendingSelectionARN = nil
            if let selectedDatabase, !databases.contains(selectedDatabase) { self.selectedDatabase = nil }
        }
    }

    private let instanceLoader: Loader
    private let clusterLoader: Loader
    private var instanceTask: Task<Void, Never>?
    private var clusterTask: Task<Void, Never>?
    private var generation = 0
    private var hasAttemptedLoad = false
    private var restoringSelection = false
    private var pendingSelectionARN: String?

    convenience init(provider: AWSServiceProvider) {
        let service = AWSRDSService(provider: provider)
        self.init(instanceLoader: { try await service.loadInstances(scope: $0) },
                  clusterLoader: { try await service.loadClusters(scope: $0) })
    }

    init(instanceLoader: @escaping Loader, clusterLoader: @escaping Loader) {
        self.instanceLoader = instanceLoader
        self.clusterLoader = clusterLoader
    }

    var databases: [RDSDatabase] { instances + clusters }
    var isLoading: Bool { isInstancesLoading || isClustersLoading }
    var error: String? {
        let messages = [instanceError, clusterError].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    var filteredDatabases: [RDSDatabase] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return databases.filter { database in
            guard kindFilter == nil || database.kind == kindFilter else { return false }
            return query.isEmpty || [database.identifier, database.arn, database.engine ?? "",
                                     database.endpoint ?? "", database.readerEndpoint ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func configure(scope: MonitoringScope?) {
        guard self.scope != scope else { return }
        reset()
        self.scope = scope
    }

    func loadIfNeeded() {
        if !hasAttemptedLoad { refresh() }
    }

    func refresh() {
        guard let scope, scope.isValid else { return }
        let selectionARN = selectedDatabase?.arn ?? pendingSelectionARN
        invalidateRequests()
        instances = []
        clusters = []
        restoringSelection = true
        selectedDatabase = nil
        restoringSelection = false
        pendingSelectionARN = selectionARN
        instanceError = nil
        clusterError = nil
        hasAttemptedLoad = true
        isInstancesLoading = true
        isClustersLoading = true
        let requestGeneration = generation
        let loadInstances = instanceLoader
        let loadClusters = clusterLoader
        instanceTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let rows = try await loadInstances(scope)
                try Task.checkCancellation()
                guard let self, self.isCurrent(requestGeneration, scope: scope) else { return }
                try self.validate(rows, kind: .instance)
                self.instances = rows
                self.isInstancesLoading = false
                self.instanceTask = nil
                self.restoreSelectionIfAvailable()
            } catch {
                guard let self, self.isCurrent(requestGeneration, scope: scope) else { return }
                self.isInstancesLoading = false
                self.instanceTask = nil
                self.instanceError = self.safeMessage(error, kind: .instance)
            }
        }
        clusterTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let rows = try await loadClusters(scope)
                try Task.checkCancellation()
                guard let self, self.isCurrent(requestGeneration, scope: scope) else { return }
                try self.validate(rows, kind: .cluster)
                self.clusters = rows
                self.isClustersLoading = false
                self.clusterTask = nil
                self.restoreSelectionIfAvailable()
            } catch {
                guard let self, self.isCurrent(requestGeneration, scope: scope) else { return }
                self.isClustersLoading = false
                self.clusterTask = nil
                self.clusterError = self.safeMessage(error, kind: .cluster)
            }
        }
    }

    func cancelLoading() {
        let instancesWereLoading = isInstancesLoading
        let clustersWereLoading = isClustersLoading
        invalidateRequests()
        let message = "Loading cancelled. Use Refresh to try again."
        if instancesWereLoading { instanceError = message }
        if clustersWereLoading { clusterError = message }
    }

    func reset() {
        invalidateRequests()
        scope = nil
        instances = []
        clusters = []
        restoringSelection = true
        selectedDatabase = nil
        restoringSelection = false
        pendingSelectionARN = nil
        hasAttemptedLoad = false
        instanceError = nil
        clusterError = nil
        searchText = ""
        kindFilter = nil
    }

    func waitForLoading() async {
        let instances = instanceTask
        let clusters = clusterTask
        await instances?.value
        await clusters?.value
    }

    private func invalidateRequests() {
        generation += 1
        instanceTask?.cancel()
        clusterTask?.cancel()
        instanceTask = nil
        clusterTask = nil
        isInstancesLoading = false
        isClustersLoading = false
    }

    private func isCurrent(_ generation: Int, scope: MonitoringScope) -> Bool {
        self.generation == generation && self.scope == scope
    }

    private func restoreSelectionIfAvailable() {
        guard let pendingSelectionARN else { return }
        if let database = databases.first(where: { $0.arn == pendingSelectionARN }) {
            self.pendingSelectionARN = nil
            restoringSelection = true
            selectedDatabase = database
            restoringSelection = false
        } else if !isLoading, error == nil {
            self.pendingSelectionARN = nil
        }
    }

    private func validate(_ rows: [RDSDatabase], kind: RDSResourceKind) throws {
        guard rows.allSatisfy({ $0.kind == kind && !$0.arn.isEmpty && !$0.identifier.isEmpty }),
              Set(rows.map(\.arn)).count == rows.count,
              Set(rows.map(\.identifier)).count == rows.count else { throw RDSError.invalidResponse }
    }

    private func safeMessage(_ error: Error, kind: RDSResourceKind) -> String {
        if error is CancellationError { return "Loading cancelled. Use Refresh to try again." }
        if let error = error as? RDSError { return error.localizedDescription }
        if let error = error as? AWSRDSService.RequestError { return error.localizedDescription }
        switch kind {
        case .instance: return "Unable to load RDS DB instances. Refresh to try again."
        case .cluster: return "Unable to load RDS DB clusters. Refresh to try again."
        }
    }
}
