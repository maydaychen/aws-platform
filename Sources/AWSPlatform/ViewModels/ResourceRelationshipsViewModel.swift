import Foundation

@MainActor
final class ResourceRelationshipsViewModel: ObservableObject {
    typealias Loader = @Sendable (ResourceRelationReference, Bool) async throws -> ResourceRelationResult

    @Published private(set) var reference: ResourceRelationReference?
    @Published private(set) var result: ResourceRelationResult?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var includesReverse = false

    private struct Snapshot {
        let reference: ResourceRelationReference
        let result: ResourceRelationResult?
        let error: String?
        let includesReverse: Bool
        let hasAttemptedLoad: Bool
    }

    private let loader: Loader
    private var task: Task<Void, Never>?
    private var generation = 0
    private var history: [Snapshot] = []
    private var hasAttemptedLoad = false

    init(loader: @escaping Loader) { self.loader = loader }

    func configure(reference: ResourceRelationReference?) {
        guard self.reference != reference else { return }
        reset()
        self.reference = reference
    }

    func load() {
        guard !hasAttemptedLoad && !isLoading else { return }
        startLoad()
    }

    func refresh() { startLoad() }

    func scanReverse() {
        guard reference?.isValid == true, reference?.canScanReverse == true else { return }
        includesReverse = true
        startLoad()
    }

    func explore(reference next: ResourceRelationReference) {
        guard !isLoading, next.canExplore, let reference, next != reference,
              next.scope == reference.scope,
              result?.sections.contains(where: { $0.nodes.contains(where: { $0.reference == next }) }) == true else { return }
        saveSnapshot(reference)
        move(to: next)
    }

    func queryRegion(_ region: String) {
        guard !isLoading, let reference, reference.service == .route53 else { return }
        let region = region.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = reference.replacingRegion(region)
        guard next.isValid else {
            error = "Enter a valid AWS region in this account's partition. No query was made."
            return
        }
        guard next != reference else { return }
        saveSnapshot(reference)
        move(to: next)
    }

    func back() {
        guard let snapshot = history.popLast() else { return }
        invalidateRequest()
        reference = snapshot.reference
        result = snapshot.result
        error = snapshot.error
        includesReverse = snapshot.includesReverse
        hasAttemptedLoad = snapshot.hasAttemptedLoad
        canGoBack = !history.isEmpty
    }

    func cancel() {
        guard isLoading else { return }
        invalidateRequest()
        error = "Relationship query cancelled. Use Refresh to try again."
    }

    func reset() {
        invalidateRequest()
        reference = nil
        result = nil
        error = nil
        history = []
        canGoBack = false
        includesReverse = false
        hasAttemptedLoad = false
    }

    func waitForLoad() async { await task?.value }

    private func saveSnapshot(_ reference: ResourceRelationReference) {
        history.append(Snapshot(reference: reference, result: result, error: error,
                                includesReverse: includesReverse, hasAttemptedLoad: hasAttemptedLoad))
        canGoBack = true
    }

    private func move(to next: ResourceRelationReference) {
        invalidateRequest()
        reference = next
        result = nil
        error = nil
        includesReverse = false
        hasAttemptedLoad = false
        startLoad()
    }

    private func startLoad() {
        guard let reference else { return }
        invalidateRequest()
        result = nil
        error = nil
        hasAttemptedLoad = true
        guard reference.isValid, reference.canExplore else {
            error = reference.scope.isValid ? ResourceRelationError.invalidResource.localizedDescription
                : ResourceRelationError.invalidScope.localizedDescription
            return
        }
        isLoading = true
        let requestGeneration = generation
        let includeReverse = includesReverse
        let loader = loader
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await loader(reference, includeReverse)
                try Task.checkCancellation()
                guard let self, self.generation == requestGeneration, self.reference == reference else { return }
                guard result.reference == reference,
                      Set(result.sections.map(\.id)).count == result.sections.count,
                      result.sections.allSatisfy({ section in
                          Set(section.nodes.map(\.id)).count == section.nodes.count && section.nodes.allSatisfy { node in
                              node.reference.map { $0.isValid && $0.scope == reference.scope } ?? true
                          }
                      }) else { throw ResourceRelationError.invalidResource }
                self.result = result
                self.isLoading = false
                self.task = nil
            } catch {
                guard let self, self.generation == requestGeneration, self.reference == reference else { return }
                self.error = self.safeMessage(error)
                self.isLoading = false
                self.task = nil
            }
        }
    }

    private func invalidateRequest() {
        generation += 1
        task?.cancel()
        task = nil
        isLoading = false
    }

    private func safeMessage(_ error: Error) -> String {
        if error is CancellationError { return "Relationship query cancelled. Use Refresh to try again." }
        if let error = error as? ResourceRelationError { return error.localizedDescription }
        return ResourceRelationError.failed.localizedDescription
    }
}
