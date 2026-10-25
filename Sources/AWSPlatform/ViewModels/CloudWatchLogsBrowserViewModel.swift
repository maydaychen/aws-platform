import Foundation

@MainActor
final class CloudWatchLogsBrowserViewModel: ObservableObject {
    typealias GroupLoader = @Sendable (MonitoringScope) async throws -> [CloudWatchLogGroup]
    typealias StreamLoader = @Sendable (MonitoringScope, CloudWatchLogGroup) async throws -> [CloudWatchLogStream]
    typealias EventLoader = @Sendable (CloudWatchLogsBrowserQuery, CloudWatchLogsBrowserCursor?) async throws -> CloudWatchLogsBrowserPage

    @Published private(set) var scope: MonitoringScope?
    @Published private(set) var groups: [CloudWatchLogGroup] = []
    @Published private(set) var streams: [CloudWatchLogStream] = []
    @Published private(set) var events: [LambdaLogEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isStreamsLoading = false
    @Published private(set) var isEventsLoading = false
    @Published private(set) var error: String?
    @Published private(set) var streamError: String?
    @Published private(set) var eventError: String?
    @Published private(set) var hasSearched = false
    @Published private(set) var limitReached = false
    @Published private(set) var query: CloudWatchLogsBrowserQuery?
    @Published var searchText = ""
    @Published var selectedGroup: CloudWatchLogGroup? {
        didSet {
            guard oldValue != selectedGroup else { return }
            if let selectedGroup, !groups.contains(selectedGroup) { self.selectedGroup = nil; return }
            clearDetail()
            if selectedGroup != nil { loadStreams() }
        }
    }
    @Published var selectedStream: String? {
        didSet { if oldValue.map({ Data($0.utf8) }) != selectedStream.map({ Data($0.utf8) }) { clearEvents() } }
    }
    @Published var timeRange: MonitoringTimeRange = .hour { didSet { if oldValue != timeRange { clearEvents() } } }
    @Published var filterPattern = "" { didSet { if Data(oldValue.utf8) != Data(filterPattern.utf8) { clearEvents() } } }

    private let groupLoader: GroupLoader
    private let streamLoader: StreamLoader
    private let eventLoader: EventLoader
    private var groupTask: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var groupGeneration = 0
    private var detailGeneration = 0
    private var eventGeneration = 0
    private var attempted = false
    private var cursor: CloudWatchLogsBrowserCursor?

    convenience init(provider: AWSServiceProvider) {
        let service = AWSCloudWatchLogsBrowserService(provider: provider)
        self.init(groupLoader: { try await service.loadGroups(scope: $0) },
                  streamLoader: { try await service.loadStreams(scope: $0, group: $1) },
                  eventLoader: { try await service.loadEvents(query: $0, cursor: $1) })
    }

    init(groupLoader: @escaping GroupLoader, streamLoader: @escaping StreamLoader, eventLoader: @escaping EventLoader) {
        self.groupLoader = groupLoader
        self.streamLoader = streamLoader
        self.eventLoader = eventLoader
    }

    var filteredGroups: [CloudWatchLogGroup] {
        groups.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) || $0.arn.localizedCaseInsensitiveContains(searchText) }
    }
    var hasMoreEvents: Bool { cursor != nil }
    var canSearch: Bool {
        guard let scope, let selectedGroup else { return false }
        return CloudWatchLogsBrowserQuery.owns(group: selectedGroup, scope: scope) &&
            (selectedStream == nil || streams.contains { $0.id == selectedStream.map { Data($0.utf8) } }) && !isEventsLoading
    }

    func configure(scope: MonitoringScope?) {
        guard self.scope != scope else { return }
        reset()
        if let scope, scope.isValid { self.scope = scope }
    }

    func loadIfNeeded() { if !attempted { refresh() } }

    func refresh() {
        guard let scope, scope.isValid else { return }
        groupGeneration += 1
        groupTask?.cancel()
        clearDetail()
        groups = []
        selectedGroup = nil
        error = nil
        attempted = true
        isLoading = true
        let generation = groupGeneration
        let loader = groupLoader
        groupTask = Task { [weak self] in
            do {
                let rows = try await loader(scope)
                try Task.checkCancellation()
                guard let self, self.groupGeneration == generation, self.scope == scope else { return }
                guard rows.allSatisfy({ CloudWatchLogsBrowserQuery.owns(group: $0, scope: scope) }),
                      Set(rows.map(\.id)).count == rows.count else { throw CloudWatchLogsBrowserError.invalidResponse }
                self.groups = rows
                self.isLoading = false
                self.groupTask = nil
            } catch {
                guard let self, self.groupGeneration == generation, self.scope == scope else { return }
                self.error = Self.message(error)
                self.isLoading = false
                self.groupTask = nil
            }
        }
    }

    func loadStreams() {
        guard let scope, let group = selectedGroup, CloudWatchLogsBrowserQuery.owns(group: group, scope: scope) else { return }
        detailGeneration += 1
        streamTask?.cancel()
        clearEvents()
        selectedStream = nil
        streams = []
        streamError = nil
        isStreamsLoading = true
        let generation = detailGeneration
        let loader = streamLoader
        streamTask = Task { [weak self] in
            do {
                let rows = try await loader(scope, group)
                try Task.checkCancellation()
                guard let self, self.detailGeneration == generation, self.scope == scope, self.selectedGroup == group else { return }
                guard rows.allSatisfy({ CloudWatchLogsBrowserQuery.validStream($0.name) }),
                      Set(rows.map(\.id)).count == rows.count else { throw CloudWatchLogsBrowserError.invalidResponse }
                self.streams = rows
                self.isStreamsLoading = false
                self.streamTask = nil
            } catch {
                guard let self, self.detailGeneration == generation, self.scope == scope, self.selectedGroup == group else { return }
                self.streamError = Self.message(error)
                self.isStreamsLoading = false
                self.streamTask = nil
            }
        }
    }

    func searchEvents(now: Date = Date()) {
        guard canSearch, let scope, let group = selectedGroup else { return }
        clearEvents()
        let query = CloudWatchLogsBrowserQuery(scope: scope, group: group, streamName: selectedStream,
            startTime: now.addingTimeInterval(-timeRange.duration), endTime: now, filterPattern: filterPattern)
        guard query.isValid else { eventError = CloudWatchLogsBrowserError.invalidScope.localizedDescription; return }
        self.query = query
        hasSearched = true
        loadPage(query: query, cursor: nil)
    }

    func loadMoreEvents() {
        guard !isEventsLoading, let query, let cursor else { return }
        loadPage(query: query, cursor: cursor)
    }

    private func loadPage(query: CloudWatchLogsBrowserQuery, cursor: CloudWatchLogsBrowserCursor?) {
        isEventsLoading = true
        eventError = nil
        let generation = eventGeneration
        let loader = eventLoader
        eventTask = Task { [weak self] in
            do {
                let page = try await loader(query, cursor)
                try Task.checkCancellation()
                guard let self, self.eventGeneration == generation, self.query == query, self.scope == query.scope,
                      self.selectedGroup == query.group else { return }
                guard page.query == query, page.cursor == nil || page.cursor?.query == query else { throw CloudWatchLogsBrowserError.invalidResponse }
                var values = Dictionary(uniqueKeysWithValues: self.events.map { ($0.id, $0) })
                for event in page.events { values[event.id] = event }
                let ordered = AWSLogsService.sorted(values.values)
                var bytes = 0
                var bounded: [LambdaLogEvent] = []
                for event in ordered {
                    guard bounded.count < 5_000, bytes + event.message.utf8.count <= 4 * 1_024 * 1_024 else {
                        self.limitReached = true
                        break
                    }
                    bytes += event.message.utf8.count
                    bounded.append(event)
                }
                self.events = bounded
                self.cursor = self.limitReached ? nil : page.cursor
                self.isEventsLoading = false
                self.eventTask = nil
            } catch {
                guard let self, self.eventGeneration == generation, self.query == query else { return }
                self.eventError = Self.message(error)
                self.isEventsLoading = false
                self.eventTask = nil
            }
        }
    }

    func cancelLoading() {
        let groupLoading = isLoading
        let streamsLoading = isStreamsLoading
        let eventsLoading = isEventsLoading
        groupGeneration += 1; detailGeneration += 1; eventGeneration += 1
        groupTask?.cancel(); streamTask?.cancel(); eventTask?.cancel()
        groupTask = nil; streamTask = nil; eventTask = nil
        isLoading = false; isStreamsLoading = false; isEventsLoading = false
        if groupLoading { error = "Loading cancelled. Use Refresh to try again." }
        if streamsLoading { streamError = "Loading cancelled. Use Refresh to try again." }
        if eventsLoading { eventError = "Loading cancelled. Use Refresh to try again." }
    }

    func reset() {
        cancelLoading()
        scope = nil
        groups = []
        selectedGroup = nil
        clearDetail()
        searchText = ""
        error = nil
        attempted = false
    }

    private func clearDetail() {
        detailGeneration += 1
        streamTask?.cancel(); streamTask = nil
        streams = []; streamError = nil; isStreamsLoading = false
        selectedStream = nil
        clearEvents()
    }

    private func clearEvents() {
        eventGeneration += 1
        eventTask?.cancel(); eventTask = nil
        events = []; cursor = nil; query = nil
        eventError = nil; isEventsLoading = false; hasSearched = false; limitReached = false
    }

    func waitForLoading() async {
        await groupTask?.value
        await streamTask?.value
        await eventTask?.value
    }

    private static func message(_ error: Error) -> String {
        if error is CancellationError { return "Loading cancelled. Use Refresh to try again." }
        return AWSCloudWatchLogsBrowserService.sanitized(error).localizedDescription
    }
}
