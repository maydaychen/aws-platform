import Foundation

@MainActor
final class CodeCommitViewModel: ObservableObject {
    typealias ListLoader = @Sendable (MonitoringScope) async throws -> [CodeCommitRepository]
    typealias RepositoryLoader = @Sendable (MonitoringScope, String) async throws -> CodeCommitRepositoryDetail
    typealias BranchesLoader = @Sendable (MonitoringScope, String) async throws -> [String]
    typealias CommitLoader = @Sendable (MonitoringScope, String, String) async throws -> CodeCommitCommit

    @Published private(set) var scope: MonitoringScope?
    @Published private(set) var repositories: [CodeCommitRepository] = []
    @Published private(set) var repositoryDetail: CodeCommitRepositoryDetail?
    @Published private(set) var branches: [String] = []
    @Published private(set) var commit: CodeCommitCommit?
    @Published private(set) var isLoading = false
    @Published private(set) var isRepositoryLoading = false
    @Published private(set) var isBranchesLoading = false
    @Published private(set) var isCommitLoading = false
    @Published private(set) var error: String?
    @Published private(set) var repositoryError: String?
    @Published private(set) var branchesError: String?
    @Published private(set) var commitError: String?
    @Published var searchText = ""
    @Published var selectedRepository: CodeCommitRepository? {
        didSet {
            guard !restoringSelection else { return }
            if let selectedRepository, !repositories.contains(selectedRepository) { self.selectedRepository = nil }
            guard oldValue != selectedRepository else { return }
            pendingListSelection = nil
            startRepositoryLoad(preferredBranch: nil, manualBranch: false)
        }
    }
    @Published var selectedBranch: String? {
        didSet {
            guard !restoringSelection else { return }
            if let selectedBranch, !branches.contains(selectedBranch) { self.selectedBranch = nil }
            guard oldValue != selectedBranch else { return }
            branchSelectionWasManual = true
            preferredBranch = nil
            refreshCommit()
        }
    }

    private struct ListSelection {
        let repository: CodeCommitRepository
        let branch: String?
        let manualBranch: Bool
    }

    private let listLoader: ListLoader
    private let repositoryLoader: RepositoryLoader
    private let branchesLoader: BranchesLoader
    private let commitLoader: CommitLoader
    private var listTask: Task<Void, Never>?
    private var repositoryTask: Task<Void, Never>?
    private var branchesTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?
    private var listGeneration = 0
    private var detailGeneration = 0
    private var commitGeneration = 0
    private var hasAttemptedLoad = false
    private var restoringSelection = false
    private var branchSelectionWasManual = false
    private var preferredBranch: String?
    private var pendingListSelection: ListSelection?

    convenience init(provider: AWSServiceProvider) {
        let service = AWSCodeCommitService(provider: provider)
        self.init(listLoader: { try await service.loadRepositories(scope: $0) },
                  repositoryLoader: { try await service.loadRepository(scope: $0, repositoryName: $1) },
                  branchesLoader: { try await service.loadBranches(scope: $0, repositoryName: $1) },
                  commitLoader: { try await service.loadCommit(scope: $0, repositoryName: $1, branchName: $2) })
    }

    init(listLoader: @escaping ListLoader, repositoryLoader: @escaping RepositoryLoader,
         branchesLoader: @escaping BranchesLoader, commitLoader: @escaping CommitLoader) {
        self.listLoader = listLoader
        self.repositoryLoader = repositoryLoader
        self.branchesLoader = branchesLoader
        self.commitLoader = commitLoader
    }

    var filteredRepositories: [CodeCommitRepository] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return repositories.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    func configure(scope: MonitoringScope?) {
        guard self.scope != scope else { return }
        reset()
        self.scope = scope
    }

    func loadIfNeeded() {
        if !hasAttemptedLoad { refresh() }
    }

    func refresh() {
        guard let scope, scope.isValid else { return }
        let selection = selectedRepository.map {
            ListSelection(repository: $0, branch: selectedBranch ?? preferredBranch, manualBranch: branchSelectionWasManual)
        } ?? pendingListSelection
        listGeneration += 1
        let generation = listGeneration
        listTask?.cancel()
        clearRepositoryState()
        restoringSelection = true
        selectedRepository = nil
        restoringSelection = false
        repositories = []
        pendingListSelection = selection
        hasAttemptedLoad = true
        isLoading = true
        error = nil
        let loader = listLoader
        listTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let rows = try await loader(scope)
                try Task.checkCancellation()
                guard let self, self.listGeneration == generation, self.scope == scope else { return }
                guard rows.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }),
                      Set(rows.map(\.id)).count == rows.count,
                      Set(rows.map(\.name)).count == rows.count else { throw CodeCommitError.invalidResponse }
                self.repositories = rows
                self.pendingListSelection = nil
                self.isLoading = false
                self.listTask = nil
                if let selection, rows.contains(selection.repository) {
                    self.restoringSelection = true
                    self.selectedRepository = selection.repository
                    self.restoringSelection = false
                    self.startRepositoryLoad(preferredBranch: selection.branch, manualBranch: selection.manualBranch)
                }
            } catch {
                guard let self, self.listGeneration == generation, self.scope == scope else { return }
                self.isLoading = false
                self.listTask = nil
                self.error = self.safeMessage(error, operation: "repositories")
            }
        }
    }

    func refreshRepository() {
        startRepositoryLoad(preferredBranch: selectedBranch ?? preferredBranch, manualBranch: branchSelectionWasManual)
    }

    func refreshCommit() {
        clearCommit()
        guard let scope, scope.isValid, let repository = selectedRepository, repositories.contains(repository),
              let branch = selectedBranch, branches.contains(branch) else { return }
        let generation = commitGeneration
        let loader = commitLoader
        isCommitLoading = true
        commitTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let commit = try await loader(scope, repository.name, branch)
                try Task.checkCancellation()
                guard let self, self.commitGeneration == generation, self.scope == scope,
                      self.selectedRepository == repository, self.selectedBranch == branch else { return }
                self.commit = commit
                self.isCommitLoading = false
                self.commitTask = nil
            } catch {
                guard let self, self.commitGeneration == generation, self.scope == scope,
                      self.selectedRepository == repository, self.selectedBranch == branch else { return }
                self.isCommitLoading = false
                self.commitTask = nil
                self.commitError = self.safeMessage(error, operation: "commit")
            }
        }
    }

    func cancelLoading() {
        let loadingList = isLoading
        let clearingRepository = selectedRepository != nil
        let loadingCommit = isCommitLoading
        listGeneration += 1
        listTask?.cancel()
        listTask = nil
        isLoading = false
        clearRepositoryState()
        let message = "Loading cancelled. Use Refresh to try again."
        if loadingList { error = message }
        if clearingRepository {
            repositoryError = message
            branchesError = message
        }
        if loadingCommit { commitError = message }
    }

    func reset() {
        cancelLoading()
        scope = nil
        repositories = []
        restoringSelection = true
        selectedRepository = nil
        restoringSelection = false
        pendingListSelection = nil
        hasAttemptedLoad = false
        error = nil
        repositoryError = nil
        branchesError = nil
        commitError = nil
        searchText = ""
    }

    func waitForLoading() async { await listTask?.value }
    func waitForDetails() async {
        let repository = repositoryTask
        let branches = branchesTask
        await repository?.value
        await branches?.value
        await commitTask?.value
    }

    private func startRepositoryLoad(preferredBranch: String?, manualBranch: Bool) {
        clearRepositoryState()
        guard let scope, scope.isValid, let repository = selectedRepository, repositories.contains(repository) else { return }
        self.preferredBranch = preferredBranch
        branchSelectionWasManual = manualBranch
        let generation = detailGeneration
        let metadataLoader = repositoryLoader
        let branchLoader = branchesLoader
        isRepositoryLoading = true
        isBranchesLoading = true
        repositoryTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let detail = try await metadataLoader(scope, repository.name)
                try Task.checkCancellation()
                guard let self, self.isCurrentDetail(generation, scope: scope, repository: repository) else { return }
                guard detail.id == repository.id, detail.name == repository.name, detail.accountID == scope.accountID else {
                    throw CodeCommitError.invalidResponse
                }
                self.repositoryDetail = detail
                self.isRepositoryLoading = false
                self.repositoryTask = nil
                self.selectPreferredOrDefaultBranch()
            } catch {
                guard let self, self.isCurrentDetail(generation, scope: scope, repository: repository) else { return }
                self.isRepositoryLoading = false
                self.repositoryTask = nil
                self.repositoryError = self.safeMessage(error, operation: "repository details")
            }
        }
        branchesTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let branches = try await branchLoader(scope, repository.name)
                try Task.checkCancellation()
                guard let self, self.isCurrentDetail(generation, scope: scope, repository: repository) else { return }
                guard branches.allSatisfy({ !$0.isEmpty }), Set(branches).count == branches.count else {
                    throw CodeCommitError.invalidResponse
                }
                self.branches = branches.sorted()
                self.isBranchesLoading = false
                self.branchesTask = nil
                self.selectPreferredOrDefaultBranch()
            } catch {
                guard let self, self.isCurrentDetail(generation, scope: scope, repository: repository) else { return }
                self.isBranchesLoading = false
                self.branchesTask = nil
                self.branchesError = self.safeMessage(error, operation: "branches")
            }
        }
    }

    private func selectPreferredOrDefaultBranch() {
        guard selectedBranch == nil, !isBranchesLoading, branchesError == nil else { return }
        let candidate: String?
        if let preferredBranch, branches.contains(preferredBranch) {
            candidate = preferredBranch
        } else if !branchSelectionWasManual, let defaultBranch = repositoryDetail?.defaultBranch,
                  branches.contains(defaultBranch) {
            candidate = defaultBranch
        } else {
            candidate = nil
        }
        guard let candidate else { return }
        preferredBranch = nil
        restoringSelection = true
        selectedBranch = candidate
        restoringSelection = false
        refreshCommit()
    }

    private func isCurrentDetail(_ generation: Int, scope: MonitoringScope, repository: CodeCommitRepository) -> Bool {
        self.scope == scope && detailGeneration == generation && selectedRepository == repository
    }

    private func clearRepositoryState() {
        detailGeneration += 1
        repositoryTask?.cancel()
        branchesTask?.cancel()
        repositoryTask = nil
        branchesTask = nil
        repositoryDetail = nil
        branches = []
        restoringSelection = true
        selectedBranch = nil
        restoringSelection = false
        preferredBranch = nil
        branchSelectionWasManual = false
        clearCommit()
        isRepositoryLoading = false
        isBranchesLoading = false
        repositoryError = nil
        branchesError = nil
    }

    private func clearCommit() {
        commitGeneration += 1
        commitTask?.cancel()
        commitTask = nil
        commit = nil
        isCommitLoading = false
        commitError = nil
    }

    private func safeMessage(_ error: Error, operation: String) -> String {
        if error is CancellationError { return "Loading cancelled. Use Refresh to try again." }
        if let error = error as? CodeCommitError { return error.localizedDescription }
        if let error = error as? AWSCodeCommitService.RequestError { return error.localizedDescription }
        switch operation {
        case "repositories": return "Unable to load CodeCommit repositories. Refresh to try again."
        case "repository details": return "Unable to load CodeCommit repository details. Refresh to try again."
        case "branches": return "Unable to load CodeCommit branches. Refresh to try again."
        default: return "Unable to load CodeCommit commit. Refresh to try again."
        }
    }
}
