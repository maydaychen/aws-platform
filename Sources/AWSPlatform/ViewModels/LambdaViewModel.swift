import Combine
import Foundation
import SotoLambda

@MainActor
final class LambdaViewModel: ObservableObject {
    typealias FunctionLoader = () async throws -> [LambdaFunctionModel]
    typealias DetailLoader = (String) async throws -> LambdaFunctionDetailModel
    typealias SummaryLoader = @Sendable (String) async throws -> LambdaFunctionSummary
    typealias CodeLoader = (LambdaFunctionModel) async throws -> LambdaFunctionModel
    typealias SectionLoader = (String, LambdaDetailSection) async throws -> LambdaDetailSectionData

    @Published var functions: [LambdaFunctionModel] = []
    @Published var selectedFunction: LambdaFunctionModel? {
        didSet {
            guard oldValue?.functionName != selectedFunction?.functionName else { return }
            activeDetailSection = nil
            releaseUnselectedCode()
            loadDetailForSelection()
        }
    }
    @Published var functionDetail: LambdaFunctionDetailModel?
    @Published private(set) var detailSectionStates: [LambdaDetailSection: LambdaDetailSectionState] = [:]
    @Published private(set) var detailSectionIssues: [LambdaDetailSection: [LambdaDetailSectionIssue]] = [:]
    @Published var isLoading = false
    @Published private(set) var isSummaryLoading = false
    @Published var isDetailLoading = false
    @Published var isCodeLoading = false
    @Published var error: String?
    @Published var summaryWarning: String?
    @Published var detailError: String?
    @Published var codeError: String?
    @Published var searchText = ""
    @Published var stateFilter = "All"
    @Published var packageFilter = "All"

    private var provider: AWSServiceProvider?
    private var scope: MonitoringScope?
    private var loadTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var sectionTasks: [LambdaDetailSection: Task<Void, Never>] = [:]
    private var codeLoadTask: Task<Void, Never>?
    private var functionLoader: FunctionLoader?
    private var detailLoader: DetailLoader?
    private var summaryLoader: SummaryLoader?
    private var codeLoader: CodeLoader?
    private var sectionLoader: SectionLoader?
    private var activeDetailSection: LambdaDetailSection?
    private var listGeneration = 0
    private var detailGeneration = 0
    private var codeGeneration = 0
    private var hasAttemptedLoad = false

    init(
        functionLoader: FunctionLoader? = nil,
        detailLoader: DetailLoader? = nil,
        summaryLoader: SummaryLoader? = nil,
        codeLoader: CodeLoader? = nil,
        sectionLoader: SectionLoader? = nil
    ) {
        self.functionLoader = functionLoader
        self.detailLoader = detailLoader
        self.summaryLoader = summaryLoader
        self.codeLoader = codeLoader
        self.sectionLoader = sectionLoader
    }

    var availableStates: [String] {
        ["All"] + Set(functions.compactMap(\.state)).sorted()
    }

    var availablePackageTypes: [String] {
        ["All"] + Set(functions.compactMap(\.packageType)).sorted()
    }

    var filteredFunctions: [LambdaFunctionModel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return functions.filter { function in
            let matchesState = stateFilter == "All" || function.state == stateFilter
            let matchesPackage = packageFilter == "All" || function.packageType == packageFilter
            let matchesSearch = query.isEmpty || [
                function.functionName, function.runtime, function.state,
                function.lastUpdateStatus, function.arn, function.handler,
                function.role, function.packageType
            ]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
            || function.tags.contains { key, value in
                key.lowercased().contains(query) || value.lowercased().contains(query)
            }
            return matchesState && matchesPackage && matchesSearch
        }
    }

    func configure(provider: AWSServiceProvider, scope: MonitoringScope, refreshImmediately: Bool = true) {
        reset()
        self.provider = provider
        self.scope = scope
        functionLoader = {
            let client = try await provider.lambdaClient(scope: scope)
            return try await LambdaReadService.fetchFunctions(client: client)
        }
        summaryLoader = { name in
            let client = try await provider.lambdaClient(scope: scope)
            let response = try await client.getFunction(.init(functionName: name))
            guard let configuration = response.configuration else {
                throw LambdaDetailError.missingConfiguration
            }
            return LambdaFunctionSummary(
                state: configuration.state?.rawValue,
                lastUpdateStatus: configuration.lastUpdateStatus?.rawValue,
                tags: response.tags ?? [:]
            )
        }
        detailLoader = { name in
            let client = try await provider.lambdaClient(scope: scope)
            return try await LambdaReadService.fetchDetail(functionName: name, client: client)
        }
        sectionLoader = { name, section in
            let client = try await provider.lambdaClient(scope: scope)
            return try await LambdaReadService.fetchSection(functionName: name, section: section, client: client)
        }
        if refreshImmediately { refresh() }
    }

    func loadIfNeeded() {
        guard !hasAttemptedLoad else { return }
        refresh()
    }

    func refresh() {
        guard functionLoader != nil else { return }
        hasAttemptedLoad = true
        listGeneration += 1
        loadTask?.cancel()
        invalidateDetail(clear: true)
        cancelCodeLoading()
        loadTask = Task { await loadFunctions() }
    }

    func waitForCurrentLoad() async { await loadTask?.value }

    func cancelLoading() {
        listGeneration += 1
        loadTask?.cancel()
        invalidateDetail(clear: false)
        cancelCodeLoading()
        isLoading = false
        isSummaryLoading = false
    }

    func reset() {
        cancelLoading()
        hasAttemptedLoad = false
        provider = nil
        scope = nil
        functions = []
        selectedFunction = nil
        functionDetail = nil
        detailSectionStates = [:]
        detailSectionIssues = [:]
        error = nil
        summaryWarning = nil
        detailError = nil
        codeError = nil
        stateFilter = "All"
        packageFilter = "All"
    }

    func loadFunctions(selectFirstIfNeeded: Bool = true) async {
        guard !Task.isCancelled, let functionLoader else { return }
        hasAttemptedLoad = true
        listGeneration += 1
        let generation = listGeneration
        invalidateDetail(clear: true)
        cancelCodeLoading()
        isLoading = true
        isSummaryLoading = false
        error = nil
        summaryWarning = nil
        defer {
            if generation == listGeneration {
                isLoading = false
                isSummaryLoading = false
            }
        }

        do {
            let loadedFunctions = try await functionLoader()
            try Task.checkCancellation()
            guard generation == listGeneration else { return }
            let selectedName = selectedFunction?.functionName
            functions = loadedFunctions
            selectedFunction = selectedName.flatMap { name in
                loadedFunctions.first { $0.functionName == name }
            } ?? (selectFirstIfNeeded ? loadedFunctions.first : nil)
            if selectedName == selectedFunction?.functionName { loadDetailForSelection() }
            isLoading = false

            // Publish the base inventory before bounded batches of GetFunction summaries.
            if let summaryLoader, !loadedFunctions.isEmpty {
                isSummaryLoading = true
                var unavailable = 0
                let names = loadedFunctions.map(\.functionName)
                let indices = Dictionary(names.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
                for offset in stride(from: 0, to: names.count, by: 4) {
                    let batch = Array(names[offset..<min(offset + 4, names.count)])
                    let summaries = try await Self.fetchSummaries(names: batch, loader: summaryLoader)
                    try Task.checkCancellation()
                    guard generation == listGeneration else { return }
                    unavailable += batch.count - summaries.count
                    for (name, summary) in summaries {
                        guard let index = indices[name], functions.indices.contains(index),
                              functions[index].functionName == name else { continue }
                        functions[index].state = summary.state
                        functions[index].lastUpdateStatus = summary.lastUpdateStatus
                        functions[index].tags = summary.tags
                        if selectedFunction?.functionName == name { selectedFunction = functions[index] }
                    }
                }
                if unavailable > 0 {
                    summaryWarning = "Status and tags unavailable for \(unavailable) function(s). Check lambda:GetFunction permission, then refresh. State filters exclude functions with unknown status."
                }
            }
            if !availableStates.contains(stateFilter) { stateFilter = "All" }
            if !availablePackageTypes.contains(packageFilter) { packageFilter = "All" }
        } catch {
            guard generation == listGeneration, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            functions = []
            selectedFunction = nil
            self.error = UserFacingError.message(for: error)
        }
    }

    func loadDetailForSelection() {
        invalidateDetail(clear: true)
        cancelCodeLoading()
        codeError = nil
        guard let name = selectedFunction?.functionName, detailLoader != nil else { return }
        let generation = detailGeneration
        isDetailLoading = true
        detailTask = Task { await performDetailLoad(functionName: name, generation: generation) }
    }

    func loadDetail(functionName: String) async {
        guard selectedFunction?.functionName == functionName, !Task.isCancelled else { return }
        invalidateDetail(clear: true)
        cancelCodeLoading()
        isDetailLoading = true
        await performDetailLoad(functionName: functionName, generation: detailGeneration)
    }

    private func performDetailLoad(functionName: String, generation: Int) async {
        guard let detailLoader, generation == detailGeneration else { return }
        defer { if generation == detailGeneration { isDetailLoading = false } }
        do {
            let detail = try await detailLoader(functionName)
            try Task.checkCancellation()
            guard generation == detailGeneration, selectedFunction?.functionName == functionName else { return }
            functionDetail = detail
            if let index = functions.firstIndex(where: { $0.functionName == functionName }) {
                functions[index].state = detail.state
                functions[index].lastUpdateStatus = detail.lastUpdateStatus
                functions[index].tags = detail.tags
                selectedFunction = functions[index]
            }
            if let activeDetailSection { loadDetailSectionIfNeeded(activeDetailSection) }
        } catch {
            guard generation == detailGeneration, !Task.isCancelled,
                  !(error is CancellationError), selectedFunction?.functionName == functionName else { return }
            detailError = UserFacingError.message(for: error)
        }
    }

    func selectDetailSection(_ section: LambdaDetailSection?) {
        activeDetailSection = section
        if let section { loadDetailSectionIfNeeded(section) }
    }

    func detailSectionState(_ section: LambdaDetailSection) -> LambdaDetailSectionState {
        detailSectionStates[section] ?? .idle
    }

    func detailSectionIssue(_ component: LambdaDetailComponent) -> LambdaDetailSectionIssue? {
        detailSectionIssues[component.section]?.first { $0.component == component }
    }

    func loadDetailSectionIfNeeded(_ section: LambdaDetailSection) {
        guard detailSectionState(section) == .idle,
              let name = selectedFunction?.functionName,
              functionDetail?.functionName == name else { return }
        guard let sectionLoader else {
            // Existing injected detail loaders may still return a complete model.
            detailSectionStates[section] = .loaded
            return
        }
        detailSectionStates[section] = .loading
        let generation = detailGeneration
        sectionTasks[section] = Task {
            do {
                let result = try await sectionLoader(name, section)
                try Task.checkCancellation()
                guard generation == detailGeneration, selectedFunction?.functionName == name,
                      let detail = functionDetail, detail.functionName == name else { return }
                functionDetail = result.merging(into: detail, section: section)
                detailSectionIssues[section] = result.issues
                detailSectionStates[section] = .loaded
            } catch {
                guard generation == detailGeneration, selectedFunction?.functionName == name else { return }
                if Task.isCancelled || error is CancellationError {
                    detailSectionStates[section] = .cancelled
                } else {
                    detailSectionStates[section] = .failed(UserFacingError.message(for: error))
                }
            }
            if generation == detailGeneration { sectionTasks[section] = nil }
        }
    }

    func retryDetailSection(_ section: LambdaDetailSection) {
        guard detailSectionState(section) != .loading else { return }
        detailSectionStates[section] = .idle
        loadDetailSectionIfNeeded(section)
    }

    func waitForDetailSection(_ section: LambdaDetailSection) async { await sectionTasks[section]?.value }

    private func invalidateDetail(clear: Bool) {
        detailGeneration += 1
        detailTask?.cancel()
        detailTask = nil
        for (section, task) in sectionTasks {
            task.cancel()
            if !clear { detailSectionStates[section] = .cancelled }
        }
        sectionTasks = [:]
        isDetailLoading = false
        if clear {
            functionDetail = nil
            detailError = nil
            detailSectionStates = [:]
            detailSectionIssues = [:]
        }
    }

    private nonisolated static func fetchSummaries(
        names: [String], loader: @escaping SummaryLoader
    ) async throws -> [String: LambdaFunctionSummary] {
        try await withThrowingTaskGroup(of: (String, LambdaFunctionSummary?).self) { group in
            for name in names {
                group.addTask {
                    try Task.checkCancellation()
                    do { return (name, try await loader(name)) }
                    catch {
                        try Task.checkCancellation()
                        if error is CancellationError { throw error }
                        return (name, nil)
                    }
                }
            }
            var summaries: [String: LambdaFunctionSummary] = [:]
            while let (name, summary) = try await group.next() {
                try Task.checkCancellation()
                summaries[name] = summary
            }
            return summaries
        }
    }

    private func releaseUnselectedCode() {
        let selectedName = selectedFunction?.functionName
        for index in functions.indices where functions[index].functionName != selectedName {
            if !functions[index].codeFiles.isEmpty { functions[index].codeFiles = [] }
        }
    }

    func loadCodeForSelection() {
        cancelCodeLoading()
        guard let selectedFunction,
              functions.contains(where: { $0.functionName == selectedFunction.functionName }),
              provider != nil || codeLoader != nil else { return }
        codeError = nil
        isCodeLoading = true
        codeLoadTask = Task { await loadCode(for: selectedFunction.functionName) }
    }

    func cancelCodeLoading() {
        codeGeneration += 1
        codeLoadTask?.cancel()
        codeLoadTask = nil
        isCodeLoading = false
    }

    func loadCode(for functionName: String) async {
        guard !Task.isCancelled,
              selectedFunction?.functionName == functionName,
              let function = functions.first(where: { $0.functionName == functionName }),
              provider != nil || codeLoader != nil else { return }
        codeGeneration += 1
        let generation = codeGeneration
        let provider = provider
        isCodeLoading = true
        codeError = nil
        defer { if generation == codeGeneration { isCodeLoading = false } }
        do {
            let updated: LambdaFunctionModel
            if let codeLoader { updated = try await codeLoader(function) }
            else if let provider {
                guard let scope else { throw AWSServiceError.notConfigured }
                updated = try await LambdaReadService.fetchCode(for: function, provider: provider, scope: scope)
            } else { return }
            try Task.checkCancellation()
            guard generation == codeGeneration,
                  let index = functions.firstIndex(where: { $0.functionName == functionName }),
                  selectedFunction?.functionName == functionName else { return }
            functions[index] = updated
            selectedFunction = updated
            releaseUnselectedCode()
        } catch {
            guard generation == codeGeneration, !Task.isCancelled,
                  !(error is CancellationError), selectedFunction?.functionName == functionName else { return }
            codeError = UserFacingError.message(for: error)
        }
    }
}
