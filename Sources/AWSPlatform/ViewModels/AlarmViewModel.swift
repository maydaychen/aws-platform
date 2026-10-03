import Foundation

@MainActor
final class AlarmViewModel: ObservableObject {
    typealias ListLoader = @Sendable (AlarmScope) async throws -> [CloudWatchAlarm]
    typealias TagLoader = @Sendable (AlarmScope, CloudWatchAlarm) async throws -> [String: String]
    typealias HistoryLoader = @Sendable (AlarmScope, CloudWatchAlarm) async throws -> [AlarmHistoryEntry]

    @Published private(set) var scope: AlarmScope?
    @Published private(set) var alarms: [CloudWatchAlarm] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var tags: [String: String] = [:]
    @Published private(set) var history: [AlarmHistoryEntry] = []
    @Published private(set) var isTagsLoading = false
    @Published private(set) var isHistoryLoading = false
    @Published private(set) var tagsError: String?
    @Published private(set) var historyError: String?
    @Published var selectedAlarm: CloudWatchAlarm? {
        didSet {
            if let selectedAlarm, !alarms.contains(selectedAlarm) {
                self.selectedAlarm = nil
            }
            guard oldValue?.arn != selectedAlarm?.arn else { return }
            refreshDetails()
        }
    }
    @Published var searchText = ""
    @Published var stateFilter = "All"
    @Published var kindFilter: AlarmKind?

    private let listLoader: ListLoader
    private let tagLoader: TagLoader
    private let historyLoader: HistoryLoader
    private var listTask: Task<Void, Never>?
    private var tagTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var listGeneration = 0
    private var detailGeneration = 0
    private var hasAttemptedLoad = false

    init(listLoader: @escaping ListLoader, tagLoader: @escaping TagLoader, historyLoader: @escaping HistoryLoader) {
        self.listLoader = listLoader
        self.tagLoader = tagLoader
        self.historyLoader = historyLoader
    }

    var availableStates: [String] { ["All"] + Set(alarms.map(\.state)).sorted() }

    var filteredAlarms: [CloudWatchAlarm] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return alarms.filter { alarm in
            guard stateFilter == "All" || alarm.state == stateFilter else { return false }
            guard kindFilter == nil || alarm.kind == kindFilter else { return false }
            guard !search.isEmpty else { return true }
            let metricValues = alarm.metrics.flatMap { metric in
                [metric.id, metric.label, metric.expression, metric.namespace, metric.metricName]
                    .compactMap { $0 }
                    + metric.dimensions.flatMap { [$0.label, $0.value] }
            }
            return ([alarm.name, alarm.arn, alarm.state, alarm.description, alarm.rule].compactMap { $0 } + metricValues)
                .contains { $0.lowercased().contains(search) }
        }
    }

    func configure(scope: AlarmScope?) {
        guard self.scope != scope else { return }
        reset()
        self.scope = scope
    }

    func loadIfNeeded() {
        guard !hasAttemptedLoad else { return }
        startListLoad()
    }

    func refresh() { startListLoad() }

    func loadAlarms() async {
        if !isLoading { startListLoad() }
        await listTask?.value
    }

    func waitForCurrentLoad() async { await listTask?.value }

    func waitForDetails() async {
        let tags = tagTask
        let history = historyTask
        await tags?.value
        await history?.value
    }

    func cancelLoading() {
        guard isLoading else { return }
        listGeneration += 1
        listTask?.cancel()
        listTask = nil
        isLoading = false
        error = "Loading cancelled. Use Refresh to try again."
    }

    func reset() {
        listGeneration += 1
        listTask?.cancel()
        listTask = nil
        scope = nil
        alarms = []
        selectedAlarm = nil
        clearDetails()
        isLoading = false
        error = nil
        searchText = ""
        stateFilter = "All"
        kindFilter = nil
        hasAttemptedLoad = false
    }

    func refreshDetails() {
        clearDetails()
        guard let scope, let alarm = selectedAlarm, alarms.contains(alarm) else { return }
        let generation = detailGeneration
        let tagLoader = self.tagLoader
        let historyLoader = self.historyLoader
        isTagsLoading = true
        isHistoryLoading = true
        tagTask = Task { [weak self] in
            do {
                let tags = try await tagLoader(scope, alarm)
                try Task.checkCancellation()
                guard let self, self.isCurrentDetail(generation, scope: scope, alarm: alarm) else { return }
                self.tags = tags
                self.isTagsLoading = false
                self.tagTask = nil
            } catch {
                guard let self, self.isCurrentDetail(generation, scope: scope, alarm: alarm) else { return }
                self.isTagsLoading = false
                self.tagTask = nil
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.tagsError = error.localizedDescription
            }
        }
        historyTask = Task { [weak self] in
            do {
                let history = try await historyLoader(scope, alarm)
                try Task.checkCancellation()
                guard let self, self.isCurrentDetail(generation, scope: scope, alarm: alarm) else { return }
                self.history = history
                self.isHistoryLoading = false
                self.historyTask = nil
            } catch {
                guard let self, self.isCurrentDetail(generation, scope: scope, alarm: alarm) else { return }
                self.isHistoryLoading = false
                self.historyTask = nil
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.historyError = error.localizedDescription
            }
        }
    }

    private func clearDetails() {
        detailGeneration += 1
        tagTask?.cancel()
        historyTask?.cancel()
        tagTask = nil
        historyTask = nil
        tags = [:]
        history = []
        tagsError = nil
        historyError = nil
        isTagsLoading = false
        isHistoryLoading = false
    }

    private func isCurrentDetail(_ generation: Int, scope: AlarmScope, alarm: CloudWatchAlarm) -> Bool {
        detailGeneration == generation && self.scope == scope && selectedAlarm?.arn == alarm.arn
    }

    private func startListLoad() {
        guard let scope else { return }
        listGeneration += 1
        let generation = listGeneration
        listTask?.cancel()
        isLoading = true
        hasAttemptedLoad = true
        error = nil
        let loader = listLoader
        listTask = Task { [weak self] in
            do {
                let alarms = try await loader(scope)
                try Task.checkCancellation()
                guard let self, self.listGeneration == generation, self.scope == scope else { return }
                let selectedARN = self.selectedAlarm?.arn
                self.alarms = alarms
                self.selectedAlarm = selectedARN.flatMap { arn in alarms.first { $0.arn == arn } }
                if self.selectedAlarm != nil { self.refreshDetails() }
                if !self.availableStates.contains(self.stateFilter) { self.stateFilter = "All" }
                self.isLoading = false
                self.listTask = nil
            } catch {
                guard let self, self.listGeneration == generation, self.scope == scope else { return }
                self.isLoading = false
                self.listTask = nil
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
