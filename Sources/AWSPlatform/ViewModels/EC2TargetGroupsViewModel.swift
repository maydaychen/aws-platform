import Foundation

@MainActor
final class EC2TargetGroupsViewModel: ObservableObject {
    typealias Loader = @Sendable (MonitoringScope, String) async throws -> ELBMembershipResult

    @Published private(set) var scope: MonitoringScope?
    @Published private(set) var instanceID: String?
    @Published private(set) var result: ELBMembershipResult?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private let loader: Loader
    private var task: Task<Void, Never>?
    private var generation = 0

    init(loader: @escaping Loader) { self.loader = loader }

    func configure(scope: MonitoringScope?, instanceID: String?) {
        guard self.scope != scope || self.instanceID != instanceID else { return }
        reset()
        self.scope = scope
        self.instanceID = instanceID
    }

    func load() { if !isLoading { refresh() } }
    func waitForLoad() async { await task?.value }

    func refresh() {
        guard let scope, let instanceID else { return }
        generation += 1
        let generation = self.generation
        task?.cancel()
        task = nil
        result = nil
        guard scope.isValid,
              instanceID.range(of: "^i-(?:[0-9a-f]{8}|[0-9a-f]{17})\\z", options: .regularExpression) != nil else {
            isLoading = false
            error = ELBError.invalidScope.localizedDescription
            return
        }
        isLoading = true
        error = nil
        let loader = self.loader
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await loader(scope, instanceID)
                try Task.checkCancellation()
                guard let self, self.generation == generation, self.scope == scope, self.instanceID == instanceID else { return }
                guard result.checkedGroupCount >= 0, result.totalGroupCount >= result.checkedGroupCount,
                      result.matches.count <= result.checkedGroupCount,
                      Set(result.matches.map(\.id)).count == result.matches.count,
                      result.matches.allSatisfy({ match in
                          match.group.targetType == "instance" && ELBARN.isTargetGroup(match.group.arn, scope: scope)
                              && !match.targets.isEmpty && match.targets.allSatisfy { $0.targetID == instanceID && $0.reason != "Target.NotRegistered" }
                      }) else { throw ELBError.invalidResponse }
                self.result = result
                self.isLoading = false
                self.task = nil
            } catch {
                guard let self, self.generation == generation, self.scope == scope, self.instanceID == instanceID else { return }
                self.isLoading = false
                self.task = nil
                self.error = self.safeMessage(error)
            }
        }
    }

    func cancel() {
        guard isLoading else { return }
        generation += 1
        task?.cancel()
        task = nil
        isLoading = false
        error = "Lookup cancelled. Use Refresh to try again."
    }

    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        scope = nil
        instanceID = nil
        result = nil
        isLoading = false
        error = nil
    }

    private func safeMessage(_ error: Error) -> String {
        if error is CancellationError { return "Lookup cancelled. Use Refresh to try again." }
        if let error = error as? ELBError { return error.localizedDescription }
        if let error = error as? AWSELBService.RequestError { return error.localizedDescription }
        return "Unable to find target group memberships. Refresh to try again."
    }
}
