import Foundation

@MainActor
final class ResourceMetricsViewModel: ObservableObject {
    typealias Loader = @Sendable (MonitoringScope, ResourceMetricTarget, MonitoringTimeRange) async throws -> ResourceMetricsSnapshot

    @Published var timeRange: MonitoringTimeRange = .hour {
        didSet {
            guard oldValue != timeRange else { return }
            clearLoad()
        }
    }
    @Published private(set) var scope: MonitoringScope?
    @Published private(set) var target: ResourceMetricTarget?
    @Published private(set) var snapshot: ResourceMetricsSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let loader: Loader
    private var loadTask: Task<Void, Never>?
    private var generation = 0

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func configure(scope: MonitoringScope?, target: ResourceMetricTarget?) {
        guard let scope, scope.isValid, let target, target.isValid else {
            reset()
            return
        }
        guard self.scope != scope || self.target != target else { return }
        reset()
        self.scope = scope
        self.target = target
    }

    func refresh() {
        guard !isLoading, let scope, scope.isValid, let target, target.isValid else { return }
        clearLoad()
        let generation = self.generation
        let range = timeRange
        let loader = self.loader
        isLoading = true
        loadTask = Task { [weak self] in
            do {
                let snapshot = try await loader(scope, target, range)
                try Task.checkCancellation()
                guard let self, self.isCurrent(generation, scope: scope, target: target, range: range) else { return }
                guard snapshot.target == target, snapshot.range == range, snapshot.period == 300,
                      snapshot.start.timeIntervalSince1970.isFinite, snapshot.end.timeIntervalSince1970.isFinite,
                      abs(snapshot.end.timeIntervalSince(snapshot.start) - range.duration) < 0.001 else {
                    throw ResourceMetricsError.invalidResponse
                }
                self.snapshot = snapshot
                self.isLoading = false
                self.loadTask = nil
            } catch {
                guard let self, self.isCurrent(generation, scope: scope, target: target, range: range) else { return }
                self.isLoading = false
                self.loadTask = nil
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.error = AWSMetricsService.userMessage(for: error)
            }
        }
    }

    func waitForCurrentLoad() async { await loadTask?.value }

    func cancelLoading() {
        guard isLoading else { return }
        clearLoad()
        error = "Metric loading cancelled. Use Refresh to try again."
    }

    func reset() {
        clearLoad()
        scope = nil
        target = nil
        timeRange = .hour
    }

    private func clearLoad() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        snapshot = nil
        isLoading = false
        error = nil
    }

    private func isCurrent(
        _ generation: Int, scope: MonitoringScope, target: ResourceMetricTarget, range: MonitoringTimeRange
    ) -> Bool {
        self.generation == generation && self.scope == scope && self.target == target && timeRange == range
    }
}
