import Foundation
import SotoS3

@MainActor
final class S3ViewModel: ObservableObject {
    @Published var buckets: [S3BucketModel] = []
    @Published var selectedBucket: S3BucketModel?
    @Published var objects: [S3ObjectModel] = []
    @Published var selectedObject: S3ObjectModel?
    @Published var currentPrefix = ""
    @Published var isLoading = false
    @Published var error: String?

    private var provider: AWSServiceProvider?

    func configure(provider: AWSServiceProvider) {
        self.provider = provider
        Task { await loadBuckets() }
    }

    func loadBuckets() async {
        guard let provider else { return }
        isLoading = true
        error = nil
        selectedBucket = nil
        selectedObject = nil
        objects = []
        currentPrefix = ""
        defer { isLoading = false }

        do {
            let client = try await provider.s3Client()
            let response = try await client.listBuckets(.init())
            buckets = (response.buckets ?? []).map { bucket in
                S3BucketModel(
                    name: bucket.name ?? "unknown",
                    region: nil,
                    creationDate: bucket.creationDate,
                    versioningEnabled: nil,
                    encryptionEnabled: nil,
                    publicAccessBlock: nil,
                    tags: [:]
                )
            }
            selectedBucket = buckets.first
        } catch {
            buckets = []
            self.error = error.localizedDescription
        }
    }

    func loadBucketDetails(name: String) async {
        guard let provider, let index = buckets.firstIndex(where: { $0.name == name }) else { return }

        do {
            let client = try await provider.s3Client()
            async let location = client.getBucketLocation(.init(bucket: name))
            async let versioning = client.getBucketVersioning(.init(bucket: name))
            async let encryption = client.getBucketEncryption(.init(bucket: name))
            async let publicAccessBlock = client.getPublicAccessBlock(.init(bucket: name))
            async let tags = client.getBucketTagging(.init(bucket: name))

            var bucket = buckets[index]
            let locationResponse = try? await location
            bucket.region = locationResponse?.locationConstraint?.rawValue ?? "us-east-1"
            bucket.versioningEnabled = (try? await versioning)?.status?.rawValue == "Enabled"
            bucket.encryptionEnabled = (try? await encryption) != nil
            bucket.publicAccessBlock = (try? await publicAccessBlock) != nil

            if let tagSet = try? await tags {
                bucket.tags = Dictionary(
                    uniqueKeysWithValues: (tagSet.tagSet ?? []).compactMap { tag in
                        guard let key = tag.key else { return nil }
                        return (key, tag.value ?? "")
                    }
                )
            }

            buckets[index] = bucket
            if selectedBucket?.name == name {
                selectedBucket = bucket
            }
        }
    }

    func selectBucket(_ bucket: S3BucketModel) {
        selectedBucket = bucket
        selectedObject = nil
        Task { await loadBucketDetails(name: bucket.name) }
    }

    func loadObjects(bucket: String, prefix: String = "") async {
        guard let provider else { return }
        isLoading = true
        error = nil
        selectedObject = nil
        currentPrefix = prefix
        defer { isLoading = false }

        do {
            let client = try await provider.s3Client()
            let response = try await client.listObjectsV2(
                .init(bucket: bucket, delimiter: "/", prefix: prefix.isEmpty ? nil : prefix)
            )

            var rows: [S3ObjectModel] = []

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

            objects = rows.sorted { $0.key < $1.key }
            selectedObject = objects.first
        } catch {
            objects = []
            self.error = error.localizedDescription
        }
    }

    func navigateToPrefix(bucket: String, prefix: String) {
        Task { await loadObjects(bucket: bucket, prefix: prefix) }
    }
}
