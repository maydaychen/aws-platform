import Foundation

@MainActor
final class CostViewModel: ObservableObject {
    typealias Loader = @Sendable (CostScope, CostQuery) async throws -> CostReport

    @Published private(set) var scope: CostScope?
    @Published private(set) var report: CostReport?
    @Published private(set) var appliedQuery: CostQuery?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var statusMessage: String?
    @Published var period: CostPeriod = .thisMonth
    @Published var customStart: Date
    @Published var customEnd: Date
    @Published var selectedRegion: String?

    private let loader: Loader
    private let now: () -> Date
    private var referenceDate: Date
    private var appliedPeriod: CostPeriod?
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var cache: [CostQuery: CostReport] = [:]
    private var cacheOrder: [CostQuery] = []

    init(loader: @escaping Loader, now: @escaping () -> Date = Date.init) {
        self.loader = loader
        self.now = now
        let today = CostDates.day(now())
        let yesterday = CostDates.calendar.date(byAdding: .day, value: -1, to: today)!
        referenceDate = today
        customEnd = yesterday
        customStart = min(CostDates.monthStart(today), yesterday)
    }

    var query: CostQuery {
        let range: CostDateRange
        if period == .custom {
            range = CostDateRange(start: customStart, end: CostDates.calendar.date(byAdding: .day, value: 1, to: customEnd)!)
        } else {
            range = period.range(now: referenceDate)
        }
        return CostQuery(range: range, region: selectedRegion, referenceDate: referenceDate)
    }

    var hasUnappliedFilters: Bool { appliedQuery.map { $0 != query } ?? false }
    var earliestDate: Date { CostDates.earliestDate(now: referenceDate) }
    var latestDate: Date { CostDates.calendar.date(byAdding: .day, value: -1, to: referenceDate)! }
    var availableRegions: [String] {
        var regions = Set(report?.regions ?? [])
        if let selectedRegion { regions.insert(selectedRegion) }
        return regions.sorted()
    }

    func configure(scope: CostScope?) {
        guard self.scope != scope else { return }
        reset()
        self.scope = scope
    }

    func loadIfNeeded() {
        guard scope != nil, appliedQuery == nil else { return }
        start(query: query, period: period, force: false)
    }

    func applyFilters() {
        referenceDate = CostDates.day(now())
        if period == .custom, CostDates.day(customStart) > CostDates.day(customEnd) {
            error = "The start date must be on or before the end date."
            return
        }
        start(query: query, period: period, force: false)
    }

    func refresh() {
        referenceDate = CostDates.day(now())
        if let appliedQuery, let appliedPeriod {
            let range = appliedPeriod == .custom ? appliedQuery.range : appliedPeriod.range(now: referenceDate)
            let refreshedQuery = CostQuery(range: range, region: appliedQuery.region, referenceDate: referenceDate)
            start(query: refreshedQuery, period: appliedPeriod, force: true)
        } else {
            start(query: query, period: period, force: true)
        }
    }

    func cancel() {
        guard isLoading else { return }
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        statusMessage = "Request cancelled. Use Refresh or Apply to try again. Completed API requests may still be billed."
    }

    func reset() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        scope = nil
        report = nil
        appliedQuery = nil
        appliedPeriod = nil
        isLoading = false
        error = nil
        statusMessage = nil
        cache = [:]
        cacheOrder = []
        referenceDate = CostDates.day(now())
        period = .thisMonth
        selectedRegion = nil
        customEnd = latestDate
        customStart = min(CostDates.monthStart(referenceDate), customEnd)
    }

    func waitForCurrentLoad() async {
        await loadTask?.value
    }

    private func start(query: CostQuery, period: CostPeriod, force: Bool) {
        guard let scope else { return }
        if period == .custom, query.range.isEmpty {
            error = "The start date must be on or before the end date."
            return
        }
        if let validation = query.validationMessage {
            error = validation
            return
        }
        guard force || !isLoading || appliedQuery != query else { return }
        generation += 1
        let requestGeneration = generation
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        error = nil
        statusMessage = nil
        if appliedQuery != query { report = nil }
        appliedQuery = query
        appliedPeriod = period

        if !force, let cached = cache[query] {
            report = cached
            touchCache(query)
            return
        }

        isLoading = true
        let loader = self.loader
        loadTask = Task { [weak self] in
            do {
                let report = try await loader(scope, query)
                try Task.checkCancellation()
                guard let self, self.generation == requestGeneration, self.scope == scope else { return }
                guard report.query == query else { throw CostError.invalidResponse }
                self.report = report
                self.cache[query] = report
                self.touchCache(query)
                self.isLoading = false
                self.loadTask = nil
            } catch {
                guard let self, self.generation == requestGeneration, self.scope == scope else { return }
                self.isLoading = false
                self.loadTask = nil
                if Task.isCancelled || error is CancellationError {
                    self.statusMessage = "Request cancelled. Use Refresh or Apply to try again."
                } else {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func touchCache(_ query: CostQuery) {
        cacheOrder.removeAll { $0 == query }
        cacheOrder.append(query)
        while cacheOrder.count > 8 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
