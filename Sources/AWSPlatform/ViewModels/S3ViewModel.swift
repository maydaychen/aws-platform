import Foundation
import SotoCore
import SotoS3

@MainActor
final class S3ViewModel: ObservableObject {
    typealias BucketLoader = () async throws -> [S3BucketModel]
    typealias DetailLoader = (S3BucketModel) async throws -> S3BucketModel
    typealias ObjectLoader = (String, String) async throws -> [S3ObjectModel]

    @Published var buckets: [S3BucketModel] = []
    @Published var selectedBucket: S3BucketModel?
    @Published var objects: [S3ObjectModel] = []
    @Published var selectedObject: S3ObjectModel?
    @Published var currentPrefix = ""
    @Published var isLoading = false
    @Published var error: String?
    @Published var bucketSearchText = ""
    @Published var objectSearchText = ""

    private var provider: AWSServiceProvider?
    private var loadTask: Task<Void, Never>?
    private var detailLoadTask: Task<Void, Never>?
    private var objectLoadTask: Task<Void, Never>?
    private var bucketLoader: BucketLoader?
    private var detailLoader: DetailLoader?
    private var objectLoader: ObjectLoader?
    private var listGeneration = 0
    private var detailGeneration = 0
    private var objectGeneration = 0

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

    func configure(provider: AWSServiceProvider) {
        reset()
        self.provider = provider
        bucketLoader = {
            let client = try await provider.s3Client()
            return try await Self.fetchBuckets(client: client)
        }
        detailLoader = { bucket in
            try await Self.fetchBucketDetails(bucket: bucket, provider: provider)
        }
        objectLoader = nil
        refresh()
    }

    func refresh() {
        loadTask?.cancel()
        loadTask = Task { await loadBuckets() }
    }

    func cancelLoading() {
        listGeneration += 1
        detailGeneration += 1
        objectGeneration += 1
        loadTask?.cancel()
        detailLoadTask?.cancel()
        objectLoadTask?.cancel()
        isLoading = false
    }

    func reset() {
        cancelLoading()
        buckets = []
        selectedBucket = nil
        objects = []
        selectedObject = nil
        currentPrefix = ""
        error = nil
    }

    func loadBuckets() async {
        guard !Task.isCancelled, let bucketLoader else { return }
        listGeneration += 1
        let generation = listGeneration
        detailGeneration += 1
        objectGeneration += 1
        detailLoadTask?.cancel()
        objectLoadTask?.cancel()
        isLoading = true
        error = nil
        selectedBucket = nil
        selectedObject = nil
        objects = []
        currentPrefix = ""
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
        provider: AWSServiceProvider
    ) async throws -> S3BucketModel {
        let name = bucket.name

        var updated = bucket
        var warnings: [String] = []
        do {
            let baseClient = try await provider.s3Client()
            do {
                let location = try await baseClient.getBucketLocation(.init(bucket: name))
                updated.region = normalizedRegion(location.locationConstraint?.rawValue)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                warnings.append("Region: \(UserFacingError.message(for: error))")
            }

            let bucketClient = try await provider.s3Client(region: updated.region)

            do {
                let versioning = try await bucketClient.getBucketVersioning(.init(bucket: name))
                updated.versioningEnabled = versioning.status?.rawValue == "Enabled"
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                warnings.append("Versioning: \(UserFacingError.message(for: error))")
            }

            do {
                _ = try await bucketClient.getBucketEncryption(.init(bucket: name))
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
                let response = try await bucketClient.getPublicAccessBlock(.init(bucket: name))
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
                let response = try await bucketClient.getBucketTagging(.init(bucket: name))
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
        selectedBucket = bucket
        selectedObject = nil
        detailLoadTask?.cancel()
        detailLoadTask = Task { await loadBucketDetails(name: bucket.name) }
    }

    func loadObjects(bucket: String, prefix: String = "") async {
        guard !Task.isCancelled, objectLoader != nil || provider != nil else { return }
        objectGeneration += 1
        let generation = objectGeneration
        listGeneration += 1
        loadTask?.cancel()
        isLoading = true
        error = nil
        selectedObject = nil
        currentPrefix = prefix
        objects = []
        defer {
            if generation == objectGeneration { isLoading = false }
        }

        do {
            let rows: [S3ObjectModel]
            if let objectLoader {
                rows = try await objectLoader(bucket, prefix)
            } else if let provider {
                rows = try await fetchObjects(bucket: bucket, prefix: prefix, provider: provider)
            } else {
                return
            }
            try Task.checkCancellation()
            guard generation == objectGeneration else { return }
            objects = rows.sorted { $0.key < $1.key }
            selectedObject = objects.first
        } catch {
            guard generation == objectGeneration, !Task.isCancelled,
                  !(error is CancellationError) else { return }
            objects = []
            self.error = UserFacingError.message(for: error)
        }
    }

    private func fetchObjects(
        bucket: String,
        prefix: String,
        provider: AWSServiceProvider
    ) async throws -> [S3ObjectModel] {
        let client = try await s3Client(forBucket: bucket, provider: provider)

        var rows: [S3ObjectModel] = []
        var continuationToken: String?

        repeat {
            try Task.checkCancellation()
            let response = try await client.listObjectsV2(
                .init(
                    bucket: bucket,
                    continuationToken: continuationToken,
                    delimiter: "/",
                    prefix: prefix.isEmpty ? nil : prefix
                )
            )
            try Task.checkCancellation()

            for entry in response.commonPrefixes ?? [] {
                guard let prefix = entry.prefix else { continue }
                rows.append(
                    S3ObjectModel(
                        key: prefix,
                        size: nil,
                        lastModified: nil,
                        storageClass: nil,
                        isPrefix: true
                    )
                )
            }

            for object in response.contents ?? [] {
                guard let key = object.key, key != prefix else { continue }
                rows.append(
                    S3ObjectModel(
                        key: key,
                        size: object.size,
                        lastModified: object.lastModified,
                        storageClass: object.storageClass?.rawValue,
                        isPrefix: false
                    )
                )
            }

            continuationToken = response.nextContinuationToken
        } while continuationToken != nil

        return rows
    }

    func navigateToPrefix(bucket: String, prefix: String) {
        objectGeneration += 1
        objectLoadTask?.cancel()
        objectLoadTask = Task { await loadObjects(bucket: bucket, prefix: prefix) }
    }

    func leaveObjectBrowser() {
        objectGeneration += 1
        objectLoadTask?.cancel()
        objects = []
        selectedObject = nil
        currentPrefix = ""
        error = nil
        isLoading = false
    }

    private func s3Client(forBucket name: String, provider: AWSServiceProvider) async throws -> S3 {
        if let bucket = buckets.first(where: { $0.name == name }), let region = bucket.region {
            return try await provider.s3Client(region: region)
        }

        let baseClient = try await provider.s3Client()
        let location = try? await baseClient.getBucketLocation(.init(bucket: name))
        try Task.checkCancellation()
        return try await provider.s3Client(region: Self.normalizedRegion(location?.locationConstraint?.rawValue))
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
        let response = try await client.listBuckets(.init())
        return (response.buckets ?? []).map { bucket in
            S3BucketModel(
                name: bucket.name ?? "unknown",
                region: nil,
                creationDate: bucket.creationDate,
                versioningEnabled: nil,
                encryptionEnabled: nil,
                publicAccessBlock: nil,
                tags: [:],
                detailError: nil
            )
        }
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
