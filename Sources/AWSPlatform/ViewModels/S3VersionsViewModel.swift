import Foundation

@MainActor
final class S3VersionsViewModel: ObservableObject {
    typealias Resolver = @Sendable (S3TransferContext, String) async throws -> S3VersionsTarget
    typealias Loader = @Sendable (S3VersionsTarget, S3VersionsCursor?) async throws -> S3VersionsPage
    @Published private(set) var context: S3TransferContext?
    @Published private(set) var key: String?
    @Published private(set) var versions: [S3ObjectVersion] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var hasLoaded = false
    @Published var searchText = ""
    private let resolver: Resolver
    private let loader: Loader
    private var target: S3VersionsTarget?
    private var cursor: S3VersionsCursor?
    private var task: Task<Void, Never>?
    private var generation = 0

    convenience init(provider: AWSServiceProvider) {
        let service = AWSS3VersionsService(provider: provider)
        self.init(resolver: { try await service.resolve(context: $0, key: $1) },
                  loader: { try await service.load(target: $0, cursor: $1) })
    }
    init(resolver: @escaping Resolver, loader: @escaping Loader) { self.resolver = resolver; self.loader = loader }

    var hasMore: Bool { cursor != nil }
    var filteredVersions: [S3ObjectVersion] {
        versions.filter { searchText.isEmpty || $0.versionID.localizedCaseInsensitiveContains(searchText) ||
            ($0.eTag?.localizedCaseInsensitiveContains(searchText) == true) }
    }

    func configure(context: S3TransferContext?, key: String?) {
        guard !S3VersionsTarget.sameContext(self.context, context) || !S3VersionsTarget.sameKey(self.key, key) else { return }
        reset()
        self.context = context
        self.key = key
    }

    func load() {
        guard let context, let key, context.isValid else { return }
        invalidate()
        versions = []; target = nil; cursor = nil; error = nil; hasLoaded = false
        start(context: context, key: key, target: nil, cursor: nil)
    }

    func loadMore() {
        guard !isLoading, let context, let key, let target, let cursor else { return }
        start(context: context, key: key, target: target, cursor: cursor)
    }

    private func start(context: S3TransferContext, key: String, target: S3VersionsTarget?, cursor: S3VersionsCursor?) {
        isLoading = true
        error = nil
        let generation = generation
        let resolver = resolver
        let loader = loader
        task = Task { [weak self] in
            do {
                let resolved: S3VersionsTarget
                if let target { resolved = target }
                else { resolved = try await resolver(context, key) }
                try Task.checkCancellation()
                guard S3VersionsTarget.sameContext(resolved.context, context), S3VersionsTarget.sameKey(resolved.key, key),
                      resolved.isValid else { throw S3VersionsError.invalidResponse }
                let page = try await loader(resolved, cursor)
                try Task.checkCancellation()
                guard let self, self.generation == generation, S3VersionsTarget.sameContext(self.context, context),
                      S3VersionsTarget.sameKey(self.key, key) else { return }
                guard page.target == resolved, page.cursor == nil || page.cursor?.target == resolved,
                      Set(page.versions.map(\.id)).count == page.versions.count else { throw S3VersionsError.invalidResponse }
                var values = Dictionary(uniqueKeysWithValues: self.versions.map { ($0.id, $0) })
                for value in page.versions { values[value.id] = value }
                self.versions = AWSS3VersionsService.sorted(values.values)
                self.target = resolved
                self.cursor = page.cursor
                self.hasLoaded = true
                self.isLoading = false
                self.task = nil
            } catch {
                guard let self, self.generation == generation, S3VersionsTarget.sameContext(self.context, context),
                      S3VersionsTarget.sameKey(self.key, key) else { return }
                self.error = error is CancellationError ? "Loading cancelled. Use Refresh to try again." : AWSS3VersionsService.sanitized(error).localizedDescription
                self.isLoading = false
                self.task = nil
            }
        }
    }

    func cancelLoading() {
        let loading = isLoading
        invalidate()
        if loading { error = "Loading cancelled. Use Refresh to try again." }
    }

    func reset() {
        invalidate()
        context = nil; key = nil; target = nil; cursor = nil
        versions = []; error = nil; hasLoaded = false; searchText = ""
    }

    private func invalidate() {
        generation += 1
        task?.cancel(); task = nil; isLoading = false
    }

    func waitForLoading() async { await task?.value }
}
