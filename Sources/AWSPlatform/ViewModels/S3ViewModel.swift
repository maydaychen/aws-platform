import Foundation
import SotoCore
import SotoS3

@MainActor
final class S3ViewModel: ObservableObject {
    typealias BucketLoader = () async throws -> [S3BucketModel]
    typealias DetailLoader = (S3BucketModel) async throws -> S3BucketModel
    typealias ObjectLoader = (String, String, String?) async throws -> S3ObjectPage

    @Published var buckets: [S3BucketModel] = []
    @Published var selectedBucket: S3BucketModel?
    @Published var objects: [S3ObjectModel] = []
    @Published var selectedObject: S3ObjectModel?
    @Published var currentPrefix = ""
    @Published var isLoading = false
    @Published var error: String?
    @Published private(set) var isLoadingMoreObjects = false
    @Published private(set) var hasLoadedObjectPage = false
    @Published private(set) var nextObjectToken: String?
    @Published private(set) var objectPageError: String?
    @Published var bucketSearchText = ""
    @Published var objectSearchText = ""

    private var provider: AWSServiceProvider?
    private var scope: MonitoringScope?
    private var loadTask: Task<Void, Never>?
    private var detailLoadTask: Task<Void, Never>?
    private var objectLoadTask: Task<Void, Never>?
    private var bucketLoader: BucketLoader?
    private var detailLoader: DetailLoader?
    private var objectLoader: ObjectLoader?
    private var listGeneration = 0
    private var detailGeneration = 0
    private var objectGeneration = 0
    private var objectBucket: String?
    private var consumedObjectTokens: Set<Data> = []
    private var hasAttemptedLoad = false

    var hasMoreObjects: Bool { nextObjectToken != nil }

    init(
        bucketLoader: BucketLoader? = nil,
        detailLoader: DetailLoader? = nil,
        objectLoader: ObjectLoader? = nil
    ) {
        self.bucketLoader = bucketLoader
        self.detailLoader = detailLoader
        self.objectLoader = objectLoader
    }

    var filteredBuckets: [S3BucketModel] {
        let query = bucketSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return buckets }
        return buckets.filter { bucket in
            bucket.name.lowercased().contains(query)
            || (bucket.region?.lowercased().contains(query) ?? false)
            || bucket.tags.contains { key, value in
                key.lowercased().contains(query) || value.lowercased().contains(query)
            }
        }
    }

    var filteredObjects: [S3ObjectModel] {
        let query = objectSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return objects }
        return objects.filter { object in
            object.key.lowercased().contains(query)
            || (object.storageClass?.lowercased().contains(query) ?? false)
        }
    }

    func configure(provider: AWSServiceProvider, scope: MonitoringScope, refreshImmediately: Bool = true) {
        reset()
        self.provider = provider
        self.scope = scope
        bucketLoader = {
            let client = try await provider.s3Client(scope: scope)
            return try await Self.fetchBuckets(client: client)
        }
        detailLoader = { bucket in
            try await Self.fetchBucketDetails(bucket: bucket, provider: provider, scope: scope)
        }
        objectLoader = nil
        if refreshImmediately { refresh() }
    }

    func loadIfNeeded() {
        guard !hasAttemptedLoad else { return }
        refresh()
    }

    func refresh() {
        guard bucketLoader != nil else { return }
        hasAttemptedLoad = true
        loadTask?.cancel()
        loadTask = Task { await loadBuckets() }
    }

    func waitForCurrentLoad() async { await loadTask?.value }

    func cancelLoading() {
        listGeneration += 1
        detailGeneration += 1
        objectGeneration += 1
        loadTask?.cancel()
        detailLoadTask?.cancel()
        objectLoadTask?.cancel()
        isLoading = false
        isLoadingMoreObjects = false
    }

    func reset() {
        cancelLoading()
        hasAttemptedLoad = false
        provider = nil
        scope = nil
        buckets = []
        selectedBucket = nil
        clearObjectBrowser()
        error = nil
    }

    func loadBuckets() async {
        guard !Task.isCancelled, let bucketLoader else { return }
        hasAttemptedLoad = true
        listGeneration += 1
        let generation = listGeneration
        detailGeneration += 1
        objectGeneration += 1
        detailLoadTask?.cancel()
        objectLoadTask?.cancel()
        isLoading = true
        error = nil
        selectedBucket = nil
        clearObjectBrowser()
        defer {
            if generation == listGeneration { isLoading = false }
        }

        do {
            let loaded = try await bucketLoader()
            try Task.checkCancellation()
            guard generation == listGeneration else { return }
            buckets = loaded
            selectedBucket = buckets.first
            if let selectedBucket {
                detailLoadTask?.cancel()
                detailLoadTask = Task { await loadBucketDetails(name: selectedBucket.name) }
            }
        } catch {
            guard generation == listGeneration, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            buckets = []
            self.error = UserFacingError.message(for: error)
        }
    }

    func loadBucketDetails(name: String) async {
        guard !Task.isCancelled, let detailLoader,
              let bucket = buckets.first(where: { $0.name == name }) else { return }
        detailGeneration += 1
        let generation = detailGeneration
        do {
            let updated = try await detailLoader(bucket)
            try Task.checkCancellation()
            guard generation == detailGeneration,
                  let index = buckets.firstIndex(where: { $0.name == name }) else { return }
            buckets[index] = updated
            if selectedBucket?.name == name { selectedBucket = updated }
        } catch {
            guard generation == detailGeneration, !Task.isCancelled,
                  !(error is CancellationError),
                  let index = buckets.firstIndex(where: { $0.name == name }) else { return }
            buckets[index].detailError = UserFacingError.message(for: error)
            if selectedBucket?.name == name { selectedBucket = buckets[index] }
        }
    }

    private static func fetchBucketDetails(
        bucket: S3BucketModel,
        provider: AWSServiceProvider,
        scope: MonitoringScope
    ) async throws -> S3BucketModel {
        let name = bucket.name

        var updated = bucket
        updated.region = nil
        updated.versioningEnabled = nil
        updated.encryptionEnabled = nil
        updated.publicAccessBlock = nil
        updated.tags = [:]
        var warnings: [String] = []
        do {
            let baseClient = try await provider.s3Client(scope: scope)
            do {
                let location = try await baseClient.getBucketLocation(.init(bucket: name, expectedBucketOwner: scope.accountID))
                updated.region = normalizedRegion(location.locationConstraint?.rawValue)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if Self.invalidatesBucket(error) { throw error }
                warnings.append("Region: \(UserFacingError.message(for: error))")
            }

            let bucketClient = try await provider.s3Client(scope: scope, region: updated.region)

            do {
                let versioning = try await bucketClient.getBucketVersioning(.init(bucket: name, expectedBucketOwner: scope.accountID))
                updated.versioningEnabled = versioning.status?.rawValue == "Enabled"
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                warnings.append("Versioning: \(UserFacingError.message(for: error))")
            }

            do {
                _ = try await bucketClient.getBucketEncryption(.init(bucket: name, expectedBucketOwner: scope.accountID))
                updated.encryptionEnabled = true
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if Self.errorCode(error) == "ServerSideEncryptionConfigurationNotFoundError" {
                    updated.encryptionEnabled = false
                } else {
                    warnings.append("Encryption: \(UserFacingError.message(for: error))")
                }
            }

            do {
                let response = try await bucketClient.getPublicAccessBlock(.init(bucket: name, expectedBucketOwner: scope.accountID))
                updated.publicAccessBlock = Self.publicAccessBlock(
                    from: response.publicAccessBlockConfiguration
                )
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if Self.errorCode(error) == "NoSuchPublicAccessBlockConfiguration" {
                    updated.publicAccessBlock = S3PublicAccessBlockModel(
                        blockPublicACLs: false,
                        ignorePublicACLs: false,
                        blockPublicPolicy: false,
                        restrictPublicBuckets: false
                    )
                } else {
                    warnings.append("Public Access Block: \(UserFacingError.message(for: error))")
                }
            }

            do {
                let response = try await bucketClient.getBucketTagging(.init(bucket: name, expectedBucketOwner: scope.accountID))
                updated.tags = Dictionary<String, String>(
                    uniqueKeysWithValues: response.tagSet.map { tag in
                        (tag.key, tag.value)
                    }
                )
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if Self.errorCode(error) == "NoSuchTagSet" {
                    updated.tags = [:]
                } else {
                    warnings.append("Tags: \(UserFacingError.message(for: error))")
                }
            }

            updated.detailError = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            updated.detailError = UserFacingError.message(for: error)
        }
        try Task.checkCancellation()
        return updated
    }

    func selectBucket(_ bucket: S3BucketModel) {
        detailGeneration += 1
        objectGeneration += 1
        objectLoadTask?.cancel()
        clearObjectBrowser()
        isLoading = false
        selectedBucket = bucket
        detailLoadTask?.cancel()
        detailLoadTask = Task { await loadBucketDetails(name: bucket.name) }
    }

    func loadObjects(bucket: String, prefix: String = "") async {
        guard let generation = beginObjectLoad(bucket: bucket, prefix: prefix) else { return }
        await loadObjectPage(bucket: bucket, prefix: prefix, token: nil, generation: generation, append: false)
    }

    func navigateToPrefix(bucket: String, prefix: String) {
        guard let generation = beginObjectLoad(bucket: bucket, prefix: prefix) else { return }
        objectLoadTask = Task {
            await loadObjectPage(bucket: bucket, prefix: prefix, token: nil, generation: generation, append: false)
        }
    }

    private func beginObjectLoad(bucket: String, prefix: String) -> Int? {
        guard !Task.isCancelled, objectLoader != nil || provider != nil else { return nil }
        objectGeneration += 1
        objectLoadTask?.cancel()
        listGeneration += 1
        loadTask?.cancel()
        clearObjectBrowser()
        objectBucket = bucket
        currentPrefix = prefix
        isLoading = true
        error = nil
        return objectGeneration
    }

    func loadMoreObjects(bucket: String) {
        guard !isLoading, objectBucket == bucket, let token = nextObjectToken else { return }
        let generation = objectGeneration
        let prefix = currentPrefix
        isLoading = true
        isLoadingMoreObjects = true
        objectPageError = nil
        objectLoadTask = Task {
            await loadObjectPage(bucket: bucket, prefix: prefix, token: token, generation: generation, append: true)
        }
    }

    private func loadObjectPage(bucket: String, prefix: String, token: String?, generation: Int, append: Bool) async {
        guard generation == objectGeneration, !Task.isCancelled else { return }
        defer {
            if generation == objectGeneration {
                isLoading = false
                isLoadingMoreObjects = false
            }
        }
        do {
            let page: S3ObjectPage
            if let objectLoader {
                page = try await objectLoader(bucket, prefix, token)
            } else if let provider, let scope {
                let client = try await s3Client(forBucket: bucket, provider: provider, scope: scope)
                try Task.checkCancellation()
                let response = try await client.listObjectsV2(S3ObjectListing.request(bucket: bucket, prefix: prefix, token: token,
                    accountID: scope.accountID))
                page = try S3ObjectListing.page(from: response, prefix: prefix)
            } else {
                return
            }
            try Task.checkCancellation()
            guard generation == objectGeneration else { return }
            if let next = page.nextContinuationToken,
               next.isEmpty || Data(next.utf8) == token.map({ Data($0.utf8) }) || consumedObjectTokens.contains(Data(next.utf8)) {
                throw S3PaginationError.invalidContinuation
            }
            if let token { consumedObjectTokens.insert(Data(token.utf8)) }
            let selection = selectedObject?.id
            objects = S3ObjectListing.merge(append ? objects : [], with: page.objects)
            nextObjectToken = page.nextContinuationToken
            hasLoadedObjectPage = true
            if append {
                selectedObject = selection.flatMap { id in objects.first { $0.id == id } }
            } else {
                selectedObject = objects.first
            }
        } catch {
            guard generation == objectGeneration, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            if Self.invalidatesBucket(error) {
                objects = []
                selectedObject = nil
                nextObjectToken = nil
                consumedObjectTokens = []
                hasLoadedObjectPage = false
            }
            if append {
                objectPageError = UserFacingError.message(for: error)
            } else {
                self.error = UserFacingError.message(for: error)
            }
        }
    }

    func leaveObjectBrowser() {
        objectGeneration += 1
        objectLoadTask?.cancel()
        clearObjectBrowser()
        error = nil
        isLoading = false
    }

    private func clearObjectBrowser() {
        objects = []
        selectedObject = nil
        currentPrefix = ""
        objectBucket = nil
        nextObjectToken = nil
        consumedObjectTokens = []
        objectPageError = nil
        hasLoadedObjectPage = false
        isLoadingMoreObjects = false
    }

    private func s3Client(forBucket name: String, provider: AWSServiceProvider, scope: MonitoringScope) async throws -> S3 {
        if let bucket = buckets.first(where: { $0.name == name }), let region = bucket.region {
            return try await provider.s3Client(scope: scope, region: region)
        }

        let baseClient = try await provider.s3Client(scope: scope)
        let location = try await baseClient.getBucketLocation(.init(bucket: name, expectedBucketOwner: scope.accountID))
        try Task.checkCancellation()
        return try await provider.s3Client(scope: scope, region: Self.normalizedRegion(location.locationConstraint?.rawValue))
    }

    private static func invalidatesBucket(_ error: Error) -> Bool {
        ["AccessDenied", "Forbidden", "403", "NoSuchBucket", "NotFound", "404"]
            .contains(AWSS3TransferService.code(error) ?? "")
    }

    private static func normalizedRegion(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "us-east-1" }
        return value == "EU" ? "eu-west-1" : value
    }

    nonisolated static func publicAccessBlock(
        from configuration: S3.PublicAccessBlockConfiguration
    ) -> S3PublicAccessBlockModel {
        S3PublicAccessBlockModel(
            blockPublicACLs: configuration.blockPublicAcls == true,
            ignorePublicACLs: configuration.ignorePublicAcls == true,
            blockPublicPolicy: configuration.blockPublicPolicy == true,
            restrictPublicBuckets: configuration.restrictPublicBuckets == true
        )
    }

    private static func fetchBuckets(client: S3) async throws -> [S3BucketModel] {
        try await S3BucketListing.load { try await client.listBuckets($0) }
    }

    private static func errorCode(_ error: Error) -> String? {
        if let error = error as? S3ErrorType {
            return error.errorCode
        }
        if let error = error as? AWSResponseError {
            return error.errorCode
        }
        if let error = error as? AWSErrorType {
            return error.errorCode
        }
        return nil
    }
}
