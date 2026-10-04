import Foundation

@MainActor
final class Route53ViewModel: ObservableObject {
    typealias ListLoader = @Sendable (Route53Scope) async throws -> [Route53HostedZone]
    typealias DetailLoader = @Sendable (Route53Scope, Route53HostedZone) async throws -> Route53ZoneDetails
    typealias RecordLoader = @Sendable (Route53Scope, Route53HostedZone) async throws -> [Route53Record]
    typealias TagLoader = @Sendable (Route53Scope, Route53HostedZone) async throws -> [String: String]

    @Published private(set) var scope: Route53Scope?
    @Published private(set) var zones: [Route53HostedZone] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var isListStale = false
    @Published private(set) var details: Route53ZoneDetails?
    @Published private(set) var records: [Route53Record] = []
    @Published private(set) var tags: [String: String] = [:]
    @Published private(set) var isDetailsLoading = false
    @Published private(set) var isRecordsLoading = false
    @Published private(set) var isTagsLoading = false
    @Published private(set) var detailsError: String?
    @Published private(set) var recordsError: String?
    @Published private(set) var tagsError: String?
    @Published var selectedZone: Route53HostedZone? {
        didSet {
            if let selectedZone, !zones.contains(selectedZone) { self.selectedZone = nil }
            guard oldValue?.id != selectedZone?.id else { return }
            recordSearchText = ""
            recordTypeFilter = "All"
            refreshDetails()
        }
    }
    @Published var searchText = ""
    @Published var privateFilter: Bool?
    @Published var recordSearchText = ""
    @Published var recordTypeFilter = "All"

    private let listLoader: ListLoader
    private let detailLoader: DetailLoader
    private let recordLoader: RecordLoader
    private let tagLoader: TagLoader
    private var listTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var recordTask: Task<Void, Never>?
    private var tagTask: Task<Void, Never>?
    private var listGeneration = 0
    private var detailGeneration = 0
    private var hasAttemptedLoad = false
    private var hasLoadedList = false

    init(listLoader: @escaping ListLoader, detailLoader: @escaping DetailLoader,
         recordLoader: @escaping RecordLoader, tagLoader: @escaping TagLoader) {
        self.listLoader = listLoader
        self.detailLoader = detailLoader
        self.recordLoader = recordLoader
        self.tagLoader = tagLoader
    }

    var filteredZones: [Route53HostedZone] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return zones.filter { zone in
            guard privateFilter == nil || zone.isPrivate == privateFilter else { return false }
            return search.isEmpty || ([zone.id, zone.name] + [zone.comment].compactMap { $0 })
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var availableRecordTypes: [String] { ["All"] + Set(records.map(\.type)).sorted() }

    var filteredRecords: [Route53Record] {
        let search = recordSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { record in
            guard recordTypeFilter == "All" || record.type.caseInsensitiveCompare(recordTypeFilter) == .orderedSame else {
                return false
            }
            guard !search.isEmpty else { return true }
            var values = [record.name, record.type, record.routingPolicy] + record.values
            if let identifier = record.setIdentifier { values.append(identifier) }
            if let ttl = record.ttl { values.append(String(ttl)) }
            if let alias = record.alias {
                values += [alias.dnsName, alias.hostedZoneID, String(alias.evaluateTargetHealth)]
            }
            values += record.routingFields.flatMap { [$0.name, $0.value] }
            return values.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    func configure(scope: Route53Scope?) {
        guard self.scope != scope else { return }
        reset()
        self.scope = scope
    }

    func loadIfNeeded() {
        guard !hasAttemptedLoad else { return }
        startListLoad()
    }

    func refresh() { startListLoad() }

    func loadZones() async {
        if !isLoading { startListLoad() }
        await listTask?.value
    }

    func waitForCurrentLoad() async { await listTask?.value }

    func waitForDetails() async {
        let detail = detailTask
        let record = recordTask
        let tag = tagTask
        await detail?.value
        await record?.value
        await tag?.value
    }

    func cancelLoading() {
        guard isLoading else { return }
        listGeneration += 1
        listTask?.cancel()
        listTask = nil
        isLoading = false
        isListStale = hasLoadedList
        error = listError("Loading cancelled. Use Refresh to try again.")
    }

    func cancelDetails() {
        detailGeneration += 1
        detailTask?.cancel()
        recordTask?.cancel()
        tagTask?.cancel()
        detailTask = nil
        recordTask = nil
        tagTask = nil
        if isDetailsLoading { detailsError = "Loading cancelled. Use Refresh details to try again." }
        if isRecordsLoading { recordsError = "Loading cancelled. Use Refresh details to try again." }
        if isTagsLoading { tagsError = "Loading cancelled. Use Refresh details to try again." }
        isDetailsLoading = false
        isRecordsLoading = false
        isTagsLoading = false
    }

    func reset() {
        listGeneration += 1
        listTask?.cancel()
        listTask = nil
        scope = nil
        zones = []
        selectedZone = nil
        clearDetails()
        isLoading = false
        error = nil
        isListStale = false
        searchText = ""
        privateFilter = nil
        recordSearchText = ""
        recordTypeFilter = "All"
        hasAttemptedLoad = false
        hasLoadedList = false
    }

    func refreshDetails() {
        clearDetails()
        guard let scope, let zone = selectedZone, zones.contains(zone) else { return }
        do { _ = try scope.partition() }
        catch {
            let message = safeMessage(error)
            detailsError = message
            recordsError = message
            tagsError = message
            return
        }
        let generation = detailGeneration
        let detailLoader = self.detailLoader
        let recordLoader = self.recordLoader
        let tagLoader = self.tagLoader
        isDetailsLoading = true
        isRecordsLoading = true
        isTagsLoading = true
        detailTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let details = try await detailLoader(scope, zone)
                try Task.checkCancellation()
                guard let self, self.isCurrentDetail(generation, scope: scope, zone: zone) else { return }
                guard details.zone.id == zone.id else { throw Route53Error.invalidResponse }
                self.details = details
                self.isDetailsLoading = false
                self.detailTask = nil
            } catch {
                guard let self, self.isCurrentDetail(generation, scope: scope, zone: zone) else { return }
                self.isDetailsLoading = false
                self.detailTask = nil
                self.detailsError = self.safeMessage(error)
            }
        }
        recordTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let records = try await recordLoader(scope, zone)
                try Task.checkCancellation()
                guard let self, self.isCurrentDetail(generation, scope: scope, zone: zone) else { return }
                self.records = records
                if !self.availableRecordTypes.contains(where: { $0.caseInsensitiveCompare(self.recordTypeFilter) == .orderedSame }) {
                    self.recordTypeFilter = "All"
                }
                self.isRecordsLoading = false
                self.recordTask = nil
            } catch {
                guard let self, self.isCurrentDetail(generation, scope: scope, zone: zone) else { return }
                self.isRecordsLoading = false
                self.recordTask = nil
                self.recordsError = self.safeMessage(error)
            }
        }
        tagTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let tags = try await tagLoader(scope, zone)
                try Task.checkCancellation()
                guard let self, self.isCurrentDetail(generation, scope: scope, zone: zone) else { return }
                self.tags = tags
                self.isTagsLoading = false
                self.tagTask = nil
            } catch {
                guard let self, self.isCurrentDetail(generation, scope: scope, zone: zone) else { return }
                self.isTagsLoading = false
                self.tagTask = nil
                self.tagsError = self.safeMessage(error)
            }
        }
    }

    private func clearDetails() {
        detailGeneration += 1
        detailTask?.cancel()
        recordTask?.cancel()
        tagTask?.cancel()
        detailTask = nil
        recordTask = nil
        tagTask = nil
        details = nil
        records = []
        tags = [:]
        detailsError = nil
        recordsError = nil
        tagsError = nil
        isDetailsLoading = false
        isRecordsLoading = false
        isTagsLoading = false
    }

    private func isCurrentDetail(_ generation: Int, scope: Route53Scope, zone: Route53HostedZone) -> Bool {
        detailGeneration == generation && self.scope == scope && selectedZone?.id == zone.id
    }

    private func startListLoad() {
        guard let scope else { return }
        listGeneration += 1
        let generation = listGeneration
        listTask?.cancel()
        listTask = nil
        hasAttemptedLoad = true
        do { _ = try scope.partition() }
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
                let zones = try await loader(scope)
                try Task.checkCancellation()
                guard let self, self.listGeneration == generation, self.scope == scope else { return }
                let selectedID = self.selectedZone?.id
                self.zones = zones
                self.selectedZone = selectedID.flatMap { id in zones.first { $0.id == id } }
                if self.selectedZone != nil { self.refreshDetails() }
                self.isLoading = false
                self.isListStale = false
                self.hasLoadedList = true
                self.listTask = nil
            } catch {
                guard let self, self.listGeneration == generation, self.scope == scope else { return }
                self.isLoading = false
                self.isListStale = self.hasLoadedList
                self.listTask = nil
                self.error = self.listError(self.safeMessage(error))
            }
        }
    }

    private func listError(_ message: String) -> String {
        isListStale ? "\(message) Showing the previous hosted zone list; it may be out of date." : message
    }

    private func safeMessage(_ error: Error) -> String {
        if error is CancellationError { return "Loading cancelled. Refresh to try again." }
        if let error = error as? Route53Error { return error.localizedDescription }
        if let error = error as? AWSRoute53Service.RequestError { return error.localizedDescription }
        return "Unable to load Route 53 data. Refresh to try again."
    }
}
