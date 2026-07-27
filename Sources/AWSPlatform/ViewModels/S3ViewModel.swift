import Foundation
import SotoCore
import SotoS3

@MainActor
final class S3ViewModel: ObservableObject {
    typealias BucketLoader = () async throws -> [S3BucketModel]

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

    init(bucketLoader: BucketLoader? = nil) {
        self.bucketLoader = bucketLoader
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
        self.provider = provider
        bucketLoader = {
            let client = try await provider.s3Client()
            return try await Self.fetchBuckets(client: client)
        }
        loadTask?.cancel()
        detailLoadTask?.cancel()
        objectLoadTask?.cancel()
        buckets = []
        selectedBucket = nil
        objects = []
        selectedObject = nil
        currentPrefix = ""
        refresh()
    }

    func refresh() {
        loadTask?.cancel()
        loadTask = Task { await loadBuckets() }
    }

    func cancelLoading() {
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
        guard let bucketLoader else { return }
        isLoading = true
        error = nil
        selectedBucket = nil
        selectedObject = nil
        objects = []
        currentPrefix = ""
        defer { isLoading = false }

        do {
            buckets = try await bucketLoader()
            try Task.checkCancellation()
            selectedBucket = buckets.first
            if let selectedBucket {
                detailLoadTask?.cancel()
                detailLoadTask = Task { await loadBucketDetails(name: selectedBucket.name) }
            }
        } catch {
            if error is CancellationError { return }
            buckets = []
            self.error = UserFacingError.message(for: error)
        }
    }

    func loadBucketDetails(name: String) async {
        guard let provider, let bucket = buckets.first(where: { $0.name == name }) else { return }

        var updated = bucket
        var warnings: [String] = []
        do {
            let baseClient = try await provider.s3Client()
            do {
                let location = try await baseClient.getBucketLocation(.init(bucket: name))
                updated.region = normalizedRegion(location.locationConstraint?.rawValue)
            } catch {
                guard !(error is CancellationError) else { return }
                warnings.append("Region: \(UserFacingError.message(for: error))")
            }

            let bucketClient = try await provider.s3Client(region: updated.region)

            do {
                let versioning = try await bucketClient.getBucketVersioning(.init(bucket: name))
                updated.versioningEnabled = versioning.status?.rawValue == "Enabled"
            } catch {
                guard !(error is CancellationError) else { return }
                warnings.append("Versioning: \(UserFacingError.message(for: error))")
            }

            do {
                _ = try await bucketClient.getBucketEncryption(.init(bucket: name))
                updated.encryptionEnabled = true
            } catch {
                guard !(error is CancellationError) else { return }
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
                guard !(error is CancellationError) else { return }
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
                guard !(error is CancellationError) else { return }
                if Self.errorCode(error) == "NoSuchTagSet" {
                    updated.tags = [:]
                } else {
                    warnings.append("Tags: \(UserFacingError.message(for: error))")
                }
            }

            updated.detailError = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
            guard let currentIndex = buckets.firstIndex(where: { $0.name == name }) else { return }
            buckets[currentIndex] = updated
            if selectedBucket?.name == name {
                selectedBucket = updated
            }
        } catch {
            if error is CancellationError { return }
            updated.detailError = UserFacingError.message(for: error)
            guard let currentIndex = buckets.firstIndex(where: { $0.name == name }) else { return }
            buckets[currentIndex] = updated
            if selectedBucket?.name == name {
                selectedBucket = updated
            }
        }
    }

    func selectBucket(_ bucket: S3BucketModel) {
        selectedBucket = bucket
        selectedObject = nil
        detailLoadTask?.cancel()
        detailLoadTask = Task { await loadBucketDetails(name: bucket.name) }
    }

    func loadObjects(bucket: String, prefix: String = "") async {
        guard let provider else { return }
        isLoading = true
        error = nil
        selectedObject = nil
        currentPrefix = prefix
        defer { isLoading = false }

        do {
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

            objects = rows.sorted { $0.key < $1.key }
            selectedObject = objects.first
        } catch {
            if error is CancellationError { return }
            objects = []
            self.error = UserFacingError.message(for: error)
        }
    }

    func navigateToPrefix(bucket: String, prefix: String) {
        objectLoadTask?.cancel()
        objectLoadTask = Task { await loadObjects(bucket: bucket, prefix: prefix) }
    }

    private func s3Client(forBucket name: String, provider: AWSServiceProvider) async throws -> S3 {
        if let bucket = buckets.first(where: { $0.name == name }), let region = bucket.region {
            return try await provider.s3Client(region: region)
        }

        let baseClient = try await provider.s3Client()
        let location = try? await baseClient.getBucketLocation(.init(bucket: name))
        return try await provider.s3Client(region: normalizedRegion(location?.locationConstraint?.rawValue))
    }

    private func normalizedRegion(_ value: String?) -> String {
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
