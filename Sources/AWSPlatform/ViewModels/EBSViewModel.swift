import Foundation

@MainActor
final class EBSViewModel: ObservableObject {
    typealias Loader = @Sendable (EBSResource.Kind, MonitoringScope) async throws -> [EBSResource]

    let kind: EBSResource.Kind
    @Published private(set) var scope: MonitoringScope?
    @Published private(set) var resources: [EBSResource] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isStale = false
    @Published private(set) var error: String?
    @Published var selectedResource: EBSResource? {
        didSet {
            if let selectedResource, !resources.contains(selectedResource) { self.selectedResource = nil }
        }
    }
    @Published var searchText = ""
    @Published var stateFilter = "All"
    private let loader: Loader
    private var task: Task<Void, Never>?
    private var generation = 0
    private var attemptedLoad = false
    private var loaded = false

    init(kind: EBSResource.Kind, loader: @escaping Loader) { self.kind = kind; self.loader = loader }

    var availableStates: [String] { ["All"] + Set(resources.map(\.state)).sorted() }
    var filteredResources: [EBSResource] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return resources.filter { (stateFilter == "All" || $0.state == stateFilter) && $0.matches(query) }
    }

    func configure(scope: MonitoringScope?) {
        guard self.scope != scope else { return }
        reset()
        self.scope = scope
    }

    func loadIfNeeded() { if !attemptedLoad { refresh() } }

    func loadResources() async {
        guard !Task.isCancelled else { return }
        if !isLoading { refresh() }
        let request = generation
        let pending = task
        await withTaskCancellationHandler {
            await pending?.value
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.generation == request { self?.cancel() }
            }
        }
    }

    func waitForLoad() async { await task?.value }

    func refresh() {
        guard let scope else { return }
        guard scope.isValid, !scope.configPath.isEmpty, !scope.credentialsPath.isEmpty else {
            error = EBSError.invalidScope.rawValue
            return
        }
        generation += 1
        let request = generation
        task?.cancel()
        attemptedLoad = true
        isLoading = true
        error = nil
        let loader = self.loader
        let kind = self.kind
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let rows = try await loader(kind, scope)
                try Task.checkCancellation()
                guard let self, self.generation == request, self.scope == scope else { return }
                guard rows.allSatisfy({ $0.kind == kind && kind.validID($0.id) && $0.ownerID == scope.accountID }),
                      Set(rows.map(\.id)).count == rows.count else { throw EBSError.invalidResponse }
                let selectedID = self.selectedResource?.id
                self.resources = rows
                self.selectedResource = selectedID.flatMap { id in rows.first { $0.id == id } }
                if !self.availableStates.contains(self.stateFilter) { self.stateFilter = "All" }
                self.loaded = true
                self.isStale = false
                self.isLoading = false
                self.error = nil
                self.task = nil
            } catch {
                guard let self, self.generation == request, self.scope == scope else { return }
                self.error = error is CancellationError ? EBSError.cancelled.rawValue : (error as? EBSError ?? .failed).rawValue
                self.isStale = self.loaded
                self.isLoading = false
                self.task = nil
            }
        }
    }

    func cancel() {
        guard isLoading else { return }
        generation += 1
        task?.cancel()
        task = nil
        isLoading = false
        isStale = loaded
        error = EBSError.cancelled.rawValue
    }

    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        scope = nil
        resources = []
        selectedResource = nil
        error = nil
        isLoading = false
        isStale = false
        attemptedLoad = false
        loaded = false
        searchText = ""
        stateFilter = "All"
    }
}
