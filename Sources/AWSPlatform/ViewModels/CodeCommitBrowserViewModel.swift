import Foundation

@MainActor
final class CodeCommitBrowserViewModel: ObservableObject {
    typealias FolderLoader = @Sendable (MonitoringScope, CodeCommitRepository, String, String) async throws -> CodeCommitFolder
    typealias FileLoader = @Sendable (MonitoringScope, CodeCommitRepository, String, String, String?) async throws -> CodeCommitFilePreview
    typealias DifferencesLoader = @Sendable (MonitoringScope, CodeCommitRepository, String?, String) async throws -> [CodeCommitFileChange]
    typealias PullRequestsLoader = @Sendable (MonitoringScope, CodeCommitRepository, String?) async throws -> [String]
    typealias PullRequestLoader = @Sendable (MonitoringScope, CodeCommitRepository, String) async throws -> CodeCommitPullRequest
    enum Work: Hashable { case folder, file, differences, changeFile, pullRequests, pullRequest }

    @Published private(set) var scope: MonitoringScope?
    @Published private(set) var repository: CodeCommitRepository?
    @Published var commitSHA = "" { didSet { if oldValue != commitSHA { clearSource() } } }
    @Published var beforeSHA = "" { didSet { if oldValue != beforeSHA { clearDifferences() } } }
    @Published var folderPath = "/" {
        didSet { if !CodeCommitPath.matches(oldValue, folderPath) { invalidate(.folder); invalidate(.file); folder = nil; file = nil } }
    }
    @Published var pullRequestStatus = "OPEN" {
        didSet {
            if oldValue != pullRequestStatus {
                invalidate(.pullRequests); invalidate(.pullRequest); pullRequestIDs = []; pullRequest = nil
            }
        }
    }
    @Published private(set) var folder: CodeCommitFolder?
    @Published private(set) var file: CodeCommitFilePreview?
    @Published private(set) var differences: [CodeCommitFileChange] = []
    @Published private(set) var selectedChange: CodeCommitFileChange?
    @Published private(set) var changeFile: CodeCommitFilePreview?
    @Published private(set) var pullRequestIDs: [String] = []
    @Published private(set) var pullRequest: CodeCommitPullRequest?
    @Published private(set) var loading: Set<Work> = []
    @Published private(set) var errors: [Work: String] = [:]
    @Published private(set) var completed: Set<Work> = []

    private let folderLoader: FolderLoader
    private let fileLoader: FileLoader
    private let differencesLoader: DifferencesLoader
    private let pullRequestsLoader: PullRequestsLoader
    private let pullRequestLoader: PullRequestLoader
    private var tasks: [Work: Task<Void, Never>] = [:]
    private var generations: [Work: UUID] = [:]
    private var suppliedCommit: CodeCommitCommit?

    convenience init(provider: AWSServiceProvider) {
        let service = AWSCodeCommitBrowserService(provider: provider)
        self.init(folderLoader: { try await service.loadFolder(scope: $0, repository: $1, commit: $2, path: $3) },
                  fileLoader: { try await service.loadFile(scope: $0, repository: $1, commit: $2, path: $3, expectedBlob: $4) },
                  differencesLoader: { try await service.loadDifferences(scope: $0, repository: $1, before: $2, after: $3) },
                  pullRequestsLoader: { try await service.loadPullRequests(scope: $0, repository: $1, status: $2) },
                  pullRequestLoader: { try await service.loadPullRequest(scope: $0, repository: $1, id: $2) })
    }

    init(folderLoader: @escaping FolderLoader, fileLoader: @escaping FileLoader,
         differencesLoader: @escaping DifferencesLoader, pullRequestsLoader: @escaping PullRequestsLoader,
         pullRequestLoader: @escaping PullRequestLoader) {
        self.folderLoader = folderLoader; self.fileLoader = fileLoader; self.differencesLoader = differencesLoader
        self.pullRequestsLoader = pullRequestsLoader; self.pullRequestLoader = pullRequestLoader
    }

    func configure(scope: MonitoringScope?, repository: CodeCommitRepository?, commit: CodeCommitCommit? = nil) {
        guard self.scope != scope || self.repository != repository || suppliedCommit != commit else { return }
        reset()
        guard let scope, scope.isValid, let repository else { return }
        self.scope = scope; self.repository = repository; suppliedCommit = commit
        commitSHA = commit?.id ?? ""; beforeSHA = commit?.parentIDs.first ?? ""
    }

    func loadFolder() {
        folder = nil; file = nil; invalidate(.file)
        guard validContext(.folder), AWSCodeCommitBrowserService.validSHA(commitSHA),
              AWSCodeCommitBrowserService.validPath(folderPath), let scope, let repository else {
            errors[.folder] = CodeCommitBrowserError.invalidInput.localizedDescription; return
        }
        let load = folderLoader, sha = commitSHA, path = folderPath
        run(.folder, load: { try await load(scope, repository, sha, path) }) { vm, value in
            guard value.commitID == sha, CodeCommitPath.matches(value.path, path) else { throw CodeCommitBrowserError.invalidResponse }
            vm.folder = value
        }
    }

    func openEntry(_ entry: CodeCommitTreeEntry) {
        guard let folder, folder.entries.contains(entry) else { return }
        if entry.kind == .folder { folderPath = entry.path; loadFolder(); return }
        guard entry.kind == .file || entry.kind == .symbolicLink, let scope, let repository else { return }
        file = nil
        let sha = commitSHA, load = fileLoader
        run(.file, load: { try await load(scope, repository, sha, entry.path, entry.objectID) }) { vm, value in
            guard value.commitID == sha, CodeCommitPath.matches(value.path, entry.path), value.blobID == entry.objectID else {
                throw CodeCommitBrowserError.invalidResponse
            }
            vm.file = value
        }
    }

    func loadDifferences() {
        differences = []; selectedChange = nil; changeFile = nil; invalidate(.changeFile)
        guard validContext(.differences), AWSCodeCommitBrowserService.validSHA(commitSHA),
              beforeSHA.isEmpty || AWSCodeCommitBrowserService.validSHA(beforeSHA), let scope, let repository else {
            errors[.differences] = CodeCommitBrowserError.invalidInput.localizedDescription; return
        }
        let after = commitSHA, before = beforeSHA.isEmpty ? nil : beforeSHA, load = differencesLoader
        run(.differences, load: { try await load(scope, repository, before, after) }) { vm, value in
            guard Set(value.map(\.id)).count == value.count else { throw CodeCommitBrowserError.invalidResponse }
            vm.differences = value
        }
    }

    func selectChange(_ change: CodeCommitFileChange) {
        guard differences.contains(change) else { return }
        invalidate(.changeFile); selectedChange = change; changeFile = nil
    }

    func loadChangeFile(before: Bool) {
        guard let selectedChange, differences.contains(selectedChange), let scope, let repository,
              let blob = before ? selectedChange.before : selectedChange.after,
              blob.mode != "160000" else { return }
        let sha = before ? beforeSHA : commitSHA
        guard AWSCodeCommitBrowserService.validSHA(sha) else { return }
        changeFile = nil
        let load = fileLoader
        run(.changeFile, load: { try await load(scope, repository, sha, blob.path, blob.id) }) { vm, value in
            guard value.commitID == sha, CodeCommitPath.matches(value.path, blob.path), value.blobID == blob.id else {
                throw CodeCommitBrowserError.invalidResponse
            }
            vm.changeFile = value
        }
    }

    func loadPullRequests() {
        pullRequestIDs = []; pullRequest = nil; invalidate(.pullRequest)
        guard validContext(.pullRequests), let scope, let repository else { return }
        let status = pullRequestStatus.isEmpty ? nil : pullRequestStatus, load = pullRequestsLoader
        run(.pullRequests, load: { try await load(scope, repository, status) }) { vm, value in
            guard Set(value).count == value.count else { throw CodeCommitBrowserError.invalidResponse }
            vm.pullRequestIDs = value
        }
    }

    func loadPullRequest(_ id: String) {
        guard pullRequestIDs.contains(id), let scope, let repository else { return }
        pullRequest = nil
        let load = pullRequestLoader
        run(.pullRequest, load: { try await load(scope, repository, id) }) { vm, value in
            guard value.id == id else { throw CodeCommitBrowserError.invalidResponse }
            vm.pullRequest = value
        }
    }

    func cancel() {
        for work in Array(tasks.keys) { invalidate(work) }
    }

    func reset() {
        cancel(); scope = nil; repository = nil; suppliedCommit = nil
        commitSHA = ""; beforeSHA = ""; folderPath = "/"; pullRequestStatus = "OPEN"
        folder = nil; file = nil; differences = []; selectedChange = nil; changeFile = nil
        pullRequestIDs = []; pullRequest = nil; errors = [:]; completed = []
    }

    func waitForLoading() async {
        let current = Array(tasks.values)
        for task in current { await task.value }
    }

    private func validContext(_ work: Work) -> Bool {
        guard scope?.isValid == true, repository != nil else {
            errors[work] = CodeCommitBrowserError.invalidInput.localizedDescription; return false
        }
        return true
    }

    private func clearSource() {
        invalidate(.folder); invalidate(.file); folder = nil; file = nil; clearDifferences()
    }

    private func clearDifferences() {
        invalidate(.differences); invalidate(.changeFile)
        differences = []; selectedChange = nil; changeFile = nil
    }

    private func invalidate(_ work: Work) {
        generations[work] = UUID(); tasks[work]?.cancel(); tasks[work] = nil
        loading.remove(work); errors[work] = nil; completed.remove(work)
    }

    private func run<Value: Sendable>(_ work: Work, load: @escaping @Sendable () async throws -> Value,
                                      apply: @escaping @MainActor (CodeCommitBrowserViewModel, Value) throws -> Void) {
        invalidate(work)
        let generation = UUID(), scope = scope, repository = repository
        generations[work] = generation; loading.insert(work)
        tasks[work] = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let value = try await load()
                try Task.checkCancellation()
                guard let self, self.generations[work] == generation, self.scope == scope, self.repository == repository else { return }
                try apply(self, value)
                self.completed.insert(work)
                self.loading.remove(work); self.tasks[work] = nil
            } catch {
                guard let self, self.generations[work] == generation, self.scope == scope, self.repository == repository else { return }
                self.loading.remove(work); self.tasks[work] = nil
                if !(error is CancellationError) { self.errors[work] = AWSCodeCommitBrowserService.sanitized(error).localizedDescription }
            }
        }
    }
}
