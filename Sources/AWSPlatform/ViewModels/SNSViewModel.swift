import Foundation

@MainActor
final class SNSViewModel: ObservableObject {
    typealias ListLoader = @Sendable (SNSScope) async throws -> [SNSTopic]
    typealias AttributeLoader = @Sendable (SNSScope, SNSTopic) async throws -> [String: String]
    typealias TagLoader = @Sendable (SNSScope, SNSTopic) async throws -> [String: String]
    typealias SubscriptionLoader = @Sendable (SNSScope, SNSTopic) async throws -> [SNSSubscription]

    @Published private(set) var scope: SNSScope?
    @Published private(set) var topics: [SNSTopic] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var attributes: [String: String] = [:]
    @Published private(set) var tags: [String: String] = [:]
    @Published private(set) var subscriptions: [SNSSubscription] = []
    @Published private(set) var isAttributesLoading = false
    @Published private(set) var isTagsLoading = false
    @Published private(set) var isSubscriptionsLoading = false
    @Published private(set) var attributesError: String?
    @Published private(set) var tagsError: String?
    @Published private(set) var subscriptionsError: String?
    @Published var selectedTopic: SNSTopic? {
        didSet {
            if let selectedTopic, !topics.contains(selectedTopic) { self.selectedTopic = nil }
            guard oldValue?.arn != selectedTopic?.arn else { return }
            refreshDetails()
        }
    }
    @Published var searchText = ""
    @Published var kindFilter: SNSTopicKind?

    private let listLoader: ListLoader
    private let attributeLoader: AttributeLoader
    private let tagLoader: TagLoader
    private let subscriptionLoader: SubscriptionLoader
    private var listTask: Task<Void, Never>?
    private var attributeTask: Task<Void, Never>?
    private var tagTask: Task<Void, Never>?
    private var subscriptionTask: Task<Void, Never>?
    private var listGeneration = 0
    private var detailGeneration = 0
    private var hasAttemptedLoad = false

    init(listLoader: @escaping ListLoader, attributeLoader: @escaping AttributeLoader,
         tagLoader: @escaping TagLoader, subscriptionLoader: @escaping SubscriptionLoader) {
        self.listLoader = listLoader
        self.attributeLoader = attributeLoader
        self.tagLoader = tagLoader
        self.subscriptionLoader = subscriptionLoader
    }

    var filteredTopics: [SNSTopic] {
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return topics.filter { topic in
            (kindFilter == nil || topic.kind == kindFilter)
                && (search.isEmpty || topic.name.lowercased().contains(search) || topic.arn.lowercased().contains(search))
        }
    }

    func configure(scope: SNSScope?) {
        guard self.scope != scope else { return }
        reset()
        self.scope = scope
    }

    func loadIfNeeded() {
        guard !hasAttemptedLoad else { return }
        startListLoad()
    }

    func refresh() { startListLoad() }

    func loadTopics() async {
        if !isLoading { startListLoad() }
        await listTask?.value
    }

    func waitForCurrentLoad() async { await listTask?.value }

    func waitForDetails() async {
        let attributes = attributeTask
        let tags = tagTask
        let subscriptions = subscriptionTask
        await attributes?.value
        await tags?.value
        await subscriptions?.value
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
        topics = []
        selectedTopic = nil
        clearDetails()
        isLoading = false
        error = nil
        searchText = ""
        kindFilter = nil
        hasAttemptedLoad = false
    }

    func refreshDetails() {
        clearDetails()
        guard let scope, let topic = selectedTopic, topics.contains(topic) else { return }
        let generation = detailGeneration
        let attributeLoader = self.attributeLoader
        let tagLoader = self.tagLoader
        let subscriptionLoader = self.subscriptionLoader
        isAttributesLoading = true
        isTagsLoading = true
        isSubscriptionsLoading = true
        attributeTask = Task { [weak self] in
            do {
                let attributes = try await attributeLoader(scope, topic)
                try Task.checkCancellation()
                guard let self, self.isCurrentDetail(generation, scope: scope, topic: topic) else { return }
                self.attributes = attributes
                self.isAttributesLoading = false
                self.attributeTask = nil
            } catch {
                guard let self, self.isCurrentDetail(generation, scope: scope, topic: topic) else { return }
                self.isAttributesLoading = false
                self.attributeTask = nil
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.attributesError = error.localizedDescription
            }
        }
        tagTask = Task { [weak self] in
            do {
                let tags = try await tagLoader(scope, topic)
                try Task.checkCancellation()
                guard let self, self.isCurrentDetail(generation, scope: scope, topic: topic) else { return }
                self.tags = tags
                self.isTagsLoading = false
                self.tagTask = nil
            } catch {
                guard let self, self.isCurrentDetail(generation, scope: scope, topic: topic) else { return }
                self.isTagsLoading = false
                self.tagTask = nil
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.tagsError = error.localizedDescription
            }
        }
        subscriptionTask = Task { [weak self] in
            do {
                let subscriptions = try await subscriptionLoader(scope, topic)
                try Task.checkCancellation()
                guard let self, self.isCurrentDetail(generation, scope: scope, topic: topic) else { return }
                self.subscriptions = subscriptions
                self.isSubscriptionsLoading = false
                self.subscriptionTask = nil
            } catch {
                guard let self, self.isCurrentDetail(generation, scope: scope, topic: topic) else { return }
                self.isSubscriptionsLoading = false
                self.subscriptionTask = nil
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self.subscriptionsError = error.localizedDescription
            }
        }
    }

    private func clearDetails() {
        detailGeneration += 1
        attributeTask?.cancel()
        tagTask?.cancel()
        subscriptionTask?.cancel()
        attributeTask = nil
        tagTask = nil
        subscriptionTask = nil
        attributes = [:]
        tags = [:]
        subscriptions = []
        attributesError = nil
        tagsError = nil
        subscriptionsError = nil
        isAttributesLoading = false
        isTagsLoading = false
        isSubscriptionsLoading = false
    }

    private func isCurrentDetail(_ generation: Int, scope: SNSScope, topic: SNSTopic) -> Bool {
        detailGeneration == generation && self.scope == scope && selectedTopic?.arn == topic.arn
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
                let topics = try await loader(scope)
                try Task.checkCancellation()
                guard let self, self.listGeneration == generation, self.scope == scope else { return }
                let selectedARN = self.selectedTopic?.arn
                self.topics = topics
                self.selectedTopic = selectedARN.flatMap { arn in topics.first { $0.arn == arn } }
                if self.selectedTopic != nil { self.refreshDetails() }
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
