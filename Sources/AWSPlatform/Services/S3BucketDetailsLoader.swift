import Foundation
import SotoS3

enum S3BucketDetailsLoader {
    static func load(bucket: S3BucketModel, provider: AWSServiceProvider, scope: MonitoringScope) async throws -> S3BucketModel {
        let name = bucket.name
        let owner = scope.accountID
        var updated = S3BucketModel(name: name, region: S3BucketRegion.validated(bucket.region, in: scope),
            creationDate: bucket.creationDate, versioningEnabled: nil, encryptionEnabled: nil,
            publicAccessBlock: nil, tags: [:], detailError: nil)
        var warnings: [String] = []

        do {
            if updated.region == nil {
                do {
                    updated.region = try await locate(name, provider: provider, scope: scope)
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || invalidatesBucket(error) ||
                        (error as? S3TransferError) == .regionUnavailable { throw error }
                    warnings.append("Region: \(UserFacingError.message(for: error))")
                }
            }
            let client = try await provider.s3Client(scope: scope, region: updated.region ?? scope.region)
            try Task.checkCancellation()

            async let versioning = field("Versioning") {
                let response = try await client.getBucketVersioning(.init(bucket: name, expectedBucketOwner: owner))
                return response.status?.rawValue == "Enabled"
            }
            async let encryption = field("Encryption", missing: ("ServerSideEncryptionConfigurationNotFoundError", false)) {
                _ = try await client.getBucketEncryption(.init(bucket: name, expectedBucketOwner: owner))
                return true
            }
            async let access = field("Public Access Block", missing: (
                "NoSuchPublicAccessBlockConfiguration", publicAccessBlock(from: .init())
            )) {
                let response = try await client.getPublicAccessBlock(.init(bucket: name, expectedBucketOwner: owner))
                return publicAccessBlock(from: response.publicAccessBlockConfiguration)
            }
            async let tags = field("Tags", missing: ("NoSuchTagSet", [String: String]())) {
                let response = try await client.getBucketTagging(.init(bucket: name, expectedBucketOwner: owner))
                return Dictionary(response.tagSet.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            }

            let (version, encrypted, block, tagValues) = try await (versioning, encryption, access, tags)
            updated.versioningEnabled = version.value
            updated.encryptionEnabled = encrypted.value
            updated.publicAccessBlock = block.value
            updated.tags = tagValues.value ?? [:]
            warnings += [version.warning, encrypted.warning, block.warning, tagValues.warning].compactMap { $0 }
            updated.detailError = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            updated.detailError = UserFacingError.message(for: error)
        }
        try Task.checkCancellation()
        return updated
    }

    static func locate(_ name: String, provider: AWSServiceProvider, scope: MonitoringScope) async throws -> String {
        let client = try await provider.s3Client(scope: scope, region: scope.region)
        try Task.checkCancellation()
        let location = try await client.getBucketLocation(.init(bucket: name, expectedBucketOwner: scope.accountID))
        try Task.checkCancellation()
        let raw = S3BucketRegion.fromLocation(location.locationConstraint?.rawValue)
        guard let region = S3BucketRegion.validated(raw, in: scope) else { throw S3TransferError.regionUnavailable }
        return region
    }

    static func invalidatesBucket(_ error: Error) -> Bool {
        ["AccessDenied", "Forbidden", "403", "NoSuchBucket", "NotFound", "404"]
            .contains(AWSS3TransferService.code(error) ?? "")
    }

    static func publicAccessBlock(from configuration: S3.PublicAccessBlockConfiguration) -> S3PublicAccessBlockModel {
        S3PublicAccessBlockModel(
            blockPublicACLs: configuration.blockPublicAcls == true,
            ignorePublicACLs: configuration.ignorePublicAcls == true,
            blockPublicPolicy: configuration.blockPublicPolicy == true,
            restrictPublicBuckets: configuration.restrictPublicBuckets == true
        )
    }

    private static func field<Value: Sendable>(
        _ name: String, missing: (code: String, value: Value)? = nil,
        read: @Sendable () async throws -> Value
    ) async throws -> (value: Value?, warning: String?) {
        do {
            try Task.checkCancellation()
            return (try await read(), nil)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if let missing, AWSS3TransferService.code(error) == missing.code { return (missing.value, nil) }
            return (nil, "\(name): \(UserFacingError.message(for: error))")
        }
    }
}
