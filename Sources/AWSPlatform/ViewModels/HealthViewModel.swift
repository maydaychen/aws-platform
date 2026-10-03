import Foundation

@MainActor
final class HealthViewModel: ObservableObject {
    typealias ListLoader = @Sendable (HealthScope) async throws -> [HealthEvent]
    typealias DetailLoader = @Sendable (HealthScope, HealthEvent) async throws -> HealthEventDetails
    typealias EntityLoader = @Sendable (HealthScope, HealthEvent) async throws -> [HealthAffectedEntity]

    @Published private(set) var scope: HealthScope?
    @Published private(set) var events: [HealthEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var details: HealthEventDetails?
    @Published private(set) var entities: [HealthAffectedEntity] = []
    @Published private(set) var isDetailLoading = false
    @Published private(set) var isEntitiesLoading = false
    @Published private(set) var detailError: String?
    @Published private(set) var entitiesError: String?
    @Published var selectedEvent: HealthEvent? {
        didSet {
            if let selectedEvent, !events.contains(selectedEvent) {
                self.selectedEvent = nil
            }
            guard oldValue?.arn != selectedEvent?.arn else { return }
            refreshDetails()
        }
    }
    @Published var searchText = ""
    @Published var statusFilter = "All"
    @Published var categoryFilter = "All"
    @Published var serviceFilter = "All"
    @Published var regionFilter = "All"

    private let listLoader: ListLoader
    private let detailLoader: DetailLoader
    private let entityLoader: EntityLoader
    private var listTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var entityTask: Task<Void, Never>?
    private var listGeneration = 0
    private var detailGeneration = 0
    private var hasAttemptedLoad = false

    init(listLoader: @escaping ListLoader, detailLoader: @escaping DetailLoader, entityLoader: @escaping EntityLoader) {
        self.listLoader = listLoader
        self.detailLoader = detailLoader
        self.entityLoader = entityLoader
    }

    var availableStatuses: [String] { options(events.map(\.status)) }
    var availableCategories: [String] { options(events.map(\.category)) }
    var availableServices: [String] { options(events.map(\.service)) }
    var availableRegions: [String] { options(events.map(\.region)) }

    var filteredEvents: [HealthEvent] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return events.filter { event in
            guard matches(event.status, filter: statusFilter),
                  matches(event.category, filter: categoryFilter),
                  matches(event.service, filter: serviceFilter),
                  matches(event.region, filter: regionFilter) else { return false }
            guard !search.isEmpty else { return true }
            return ([event.arn, event.service, event.typeCode, event.category, event.status, event.region]
                + [event.availabilityZone].compactMap { $0 })
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    func configure(scope: HealthScope?) {
        guard self.scope != scope else { return }
        reset()
        self.scope = scope
    }

    func loadIfNeeded() {
        guard !hasAttemptedLoad else { return }
        startListLoad()
    }

    func refresh() { startListLoad() }

    func loadEvents() async {
        if !isLoading { startListLoad() }
        await listTask?.value
    }

    func waitForCurrentLoad() async { await listTask?.value }

    func waitForDetails() async {
        let detail = detailTask
        let entity = entityTask
        await detail?.value
        await entity?.value
    }

    func cancelLoading() {
        guard isLoading else { return }
        listGeneration += 1
        listTask?.cancel()
        listTask = nil
        isLoading = false
        error = listError("Loading cancelled. Use Refresh to try again.")
    }

    func cancelDetails() {
        detailGeneration += 1
        detailTask?.cancel()
        entityTask?.cancel()
        detailTask = nil
        entityTask = nil
        if isDetailLoading { detailError = "Loading cancelled. Use Refresh details to try again." }
        if isEntitiesLoading { entitiesError = "Loading cancelled. Use Refresh details to try again." }
        isDetailLoading = false
        isEntitiesLoading = false
    }

    func reset() {
        listGeneration += 1
        listTask?.cancel()
        listTask = nil
        scope = nil
        events = []
        selectedEvent = nil
        clearDetails()
        isLoading = false
        error = nil
        searchText = ""
        statusFilter = "All"
        categoryFilter = "All"
        serviceFilter = "All"
        regionFilter = "All"
        hasAttemptedLoad = false
    }

    func refreshDetails() {
        clearDetails()
        guard let scope, let event = selectedEvent, events.contains(event) else { return }
        do { _ = try scope.endpoint() }
        catch {
            detailError = safeMessage(error)
            entitiesError = safeMessage(error)
            return
        }
        let generation = detailGeneration
        let detailLoader = self.detailLoader
        let entityLoader = self.entityLoader
        isDetailLoading = true
        isEntitiesLoading = true
        detailTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let details = try await detailLoader(scope, event)
                try Task.checkCancellation()
                guard let self, self.isCurrentDetail(generation, scope: scope, event: event) else { return }
                self.details = details
                self.isDetailLoading = false
                self.detailTask = nil
            } catch {
                guard let self, self.isCurrentDetail(generation, scope: scope, event: event) else { return }
                self.isDetailLoading = false
                self.detailTask = nil
                self.detailError = self.safeMessage(error)
            }
        }
        entityTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let entities = try await entityLoader(scope, event)
                try Task.checkCancellation()
                guard let self, self.isCurrentDetail(generation, scope: scope, event: event) else { return }
                self.entities = entities
                self.isEntitiesLoading = false
                self.entityTask = nil
            } catch {
                guard let self, self.isCurrentDetail(generation, scope: scope, event: event) else { return }
                self.isEntitiesLoading = false
                self.entityTask = nil
                self.entitiesError = self.safeMessage(error)
            }
        }
    }

    private func clearDetails() {
        detailGeneration += 1
        detailTask?.cancel()
        entityTask?.cancel()
        detailTask = nil
        entityTask = nil
        details = nil
        entities = []
        detailError = nil
        entitiesError = nil
        isDetailLoading = false
        isEntitiesLoading = false
    }

    private func isCurrentDetail(_ generation: Int, scope: HealthScope, event: HealthEvent) -> Bool {
        detailGeneration == generation && self.scope == scope && selectedEvent?.arn == event.arn
    }

    private func startListLoad() {
        guard let scope else { return }
        listGeneration += 1
        let generation = listGeneration
        listTask?.cancel()
        listTask = nil
        hasAttemptedLoad = true
        do { _ = try scope.endpoint() }
        catch {
            isLoading = false
            self.error = safeMessage(error)
            return
        }
        isLoading = true
        error = nil
        let loader = listLoader
        listTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let events = try await loader(scope)
                try Task.checkCancellation()
                guard let self, self.listGeneration == generation, self.scope == scope else { return }
                let selectedARN = self.selectedEvent?.arn
                self.events = events
                self.selectedEvent = selectedARN.flatMap { arn in events.first { $0.arn == arn } }
                if self.selectedEvent != nil { self.refreshDetails() }
                if !self.availableStatuses.contains(self.statusFilter) { self.statusFilter = "All" }
                if !self.availableCategories.contains(self.categoryFilter) { self.categoryFilter = "All" }
                if !self.availableServices.contains(self.serviceFilter) { self.serviceFilter = "All" }
                if !self.availableRegions.contains(self.regionFilter) { self.regionFilter = "All" }
                self.isLoading = false
                self.listTask = nil
            } catch {
                guard let self, self.listGeneration == generation, self.scope == scope else { return }
                self.isLoading = false
                self.listTask = nil
                self.error = self.listError(self.safeMessage(error))
            }
        }
    }

    private func listError(_ message: String) -> String {
        events.isEmpty ? message : "\(message) Showing the previous event list; it may be out of date."
    }

    private func safeMessage(_ error: Error) -> String {
        if error is CancellationError { return "Loading cancelled. Refresh to try again." }
        if let error = error as? HealthError { return error.localizedDescription }
        if let error = error as? AWSHealthService.RequestError { return error.localizedDescription }
        return "Unable to load AWS Health data. Refresh to try again."
    }

    private func options(_ values: [String]) -> [String] {
        ["All"] + Set(values.filter { !$0.isEmpty && $0 != "All" }).sorted()
    }

    private func matches(_ value: String, filter: String) -> Bool {
        filter == "All" || value.caseInsensitiveCompare(filter) == .orderedSame
    }
}
