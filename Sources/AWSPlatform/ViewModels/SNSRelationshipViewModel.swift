import Foundation

@MainActor
final class SNSRelationshipViewModel: ObservableObject {
    typealias Loader = @Sendable (SNSScope) async throws -> [CloudWatchAlarm]

    @Published private(set) var scope: SNSScope?
    @Published private(set) var topic: SNSTopic?
    @Published private(set) var sources: [SNSAlarmRelationship] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var hasLoaded = false

    private let loader: Loader
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var hasAttemptedLoad = false

    init(loader: @escaping Loader) { self.loader = loader }

    func load(scope: SNSScope?, topic: SNSTopic) {
        guard let scope else {
            reset()
            return
        }
        if self.scope == scope, self.topic == topic, hasAttemptedLoad { return }
        reset()
        self.scope = scope
        self.topic = topic
        startLoad()
    }

    func refresh() { startLoad() }

    func waitForLoad() async { await loadTask?.value }

    func reset() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        scope = nil
        topic = nil
        sources = []
        isLoading = false
        error = nil
        hasLoaded = false
        hasAttemptedLoad = false
    }

    private func startLoad() {
        guard let scope, let topic else { return }
        generation += 1
        let requestGeneration = generation
        loadTask?.cancel()
        sources = []
        isLoading = true
        error = nil
        hasLoaded = false
        hasAttemptedLoad = true
        let loader = self.loader
        loadTask = Task { [weak self] in
            do {
                let alarms = try await loader(scope)
                try Task.checkCancellation()
                guard let self, self.generation == requestGeneration,
                      self.scope == scope, self.topic == topic else { return }
                self.sources = SNSRelationshipMapping.alarmSources(alarms, topic: topic, scope: scope)
                self.isLoading = false
                self.hasLoaded = true
                self.loadTask = nil
            } catch {
                guard let self, self.generation == requestGeneration,
                      self.scope == scope, self.topic == topic else { return }
                self.sources = []
                self.isLoading = false
                self.hasLoaded = false
                self.loadTask = nil
                self.error = "Upstream check is incomplete. \(Self.safeMessage(error))"
            }
        }
    }

    private static func safeMessage(_ error: Error) -> String {
        if error is CancellationError { return "The request was cancelled. Refresh to check again." }
        if let error = error as? AlarmError { return error.localizedDescription }
        if let error = error as? AWSAlarmService.RequestError { return error.localizedDescription }
        if error is URLError { return "Unable to reach AWS. Check the network, then refresh." }
        return "Unable to read CloudWatch alarm configuration. Check the selected profile, region and permissions, then refresh."
    }
}
