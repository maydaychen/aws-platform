import Foundation

@MainActor
final class LambdaLogsViewModel: ObservableObject {
    typealias Loader = @Sendable (LambdaLogQuery, LambdaLogCursor?) async throws -> LambdaLogPage
    static let maximumEvents = 5_000
    static let maximumMessageBytes = 8 * 1_024 * 1_024

    @Published var timeRange: MonitoringTimeRange = .hour {
        didSet { if oldValue != timeRange { clearSearch() } }
    }
    @Published var filterPattern = "" {
        didSet { if oldValue != filterPattern { clearSearch() } }
    }
    @Published private(set) var scope: MonitoringScope?
    @Published private(set) var context: LambdaLogContext?
    @Published private(set) var events: [LambdaLogEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = false
    @Published private(set) var hasSearched = false
    @Published private(set) var query: LambdaLogQuery?
    @Published private(set) var limitReached = false

    private let loader: Loader
    private let now: @Sendable () -> Date
    private var cursor: LambdaLogCursor?
    private var loadTask: Task<Void, Never>?
    private var generation = 0

    init(loader: @escaping Loader, now: @escaping @Sendable () -> Date = { Date() }) {
        self.loader = loader
        self.now = now
    }

    func configure(scope: MonitoringScope?, context: LambdaLogContext?) {
        guard let scope, scope.isValid, let context, context.isValid else {
            reset()
            return
        }
        guard self.scope != scope || self.context != context else { return }
        reset()
        self.scope = scope
        self.context = context
    }

    func search() {
        clearSearch()
        guard let scope, let context else { return }
        let end = now()
        let query = LambdaLogQuery(scope: scope, context: context,
                                   startTime: end.addingTimeInterval(-timeRange.duration), endTime: end,
                                   filterPattern: filterPattern)
        guard query.isValid else {
            error = LambdaLogsError.invalidQuery.localizedDescription
            return
        }
        self.query = query
        hasSearched = true
        startLoad(query: query, cursor: nil)
    }

    func loadMore() {
        guard !isLoading, !limitReached, hasMore, let query, let cursor else { return }
        startLoad(query: query, cursor: cursor)
    }

    func waitForCurrentLoad() async { await loadTask?.value }

    func cancelLoading() {
        guard isLoading else { return }
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        error = "The log search was cancelled before it completed. Search again or continue loading to retry."
    }

    func reset() {
        clearSearch()
        scope = nil
        context = nil
        timeRange = .hour
        filterPattern = ""
    }

    private func clearSearch() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        events = []
        isLoading = false
        error = nil
        hasMore = false
        hasSearched = false
        query = nil
        cursor = nil
        limitReached = false
    }

    private func startLoad(query: LambdaLogQuery, cursor: LambdaLogCursor?) {
        guard scope == query.scope, context == query.context else { return }
        generation += 1
        let requestGeneration = generation
        loadTask?.cancel()
        isLoading = true
        error = nil
        let loader = self.loader
        loadTask = Task { [weak self] in
            do {
                let page = try await loader(query, cursor)
                try Task.checkCancellation()
                guard let self, self.generation == requestGeneration, self.scope == query.scope,
                      self.context == query.context, self.query == query else { return }
                guard page.query == query, page.cursor == nil || page.cursor?.query == query else {
                    throw LambdaLogsError.invalidResponse
                }
                var combined = Dictionary(self.events.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
                for event in page.events { combined[event.id] = event }
                let sorted = AWSLogsService.sorted(combined.values)
                var visible: [LambdaLogEvent] = []
                var bytes = 0
                for event in sorted.prefix(Self.maximumEvents) {
                    let size = event.message.utf8.count
                    guard size <= Self.maximumMessageBytes - bytes else { break }
                    visible.append(event)
                    bytes += size
                }
                self.limitReached = visible.count < sorted.count ||
                    (visible.count == Self.maximumEvents && page.cursor != nil) ||
                    (bytes == Self.maximumMessageBytes && page.cursor != nil)
                self.events = visible
                self.cursor = self.limitReached ? nil : page.cursor
                self.hasMore = self.cursor != nil
                self.isLoading = false
                self.loadTask = nil
            } catch {
                guard let self, self.generation == requestGeneration, self.scope == query.scope,
                      self.context == query.context, self.query == query else { return }
                self.isLoading = false
                self.loadTask = nil
                self.error = error is CancellationError ? "The log request was cancelled. Search again to retry." :
                    AWSLogsService.sanitized(error).localizedDescription
            }
        }
    }
}
