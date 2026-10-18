import Foundation

struct S3VersionsTarget: Hashable, Sendable {
    let context: S3TransferContext
    let key: String
    let region: String

    var isValid: Bool {
        guard context.isValid, !context.scope.configPath.isEmpty, !context.scope.credentialsPath.isEmpty,
              !context.bucket.hasSuffix("--x-s3"), key.utf8.starts(with: context.prefix.utf8),
              Self.validKey(key) else { return false }
        let regionalScope = MonitoringScope(profile: context.scope.profile,
            identity: .init(account: context.scope.accountID, arn: context.scope.principalARN, userID: ""),
            region: region, paths: context.scope.paths)
        return regionalScope.isValid && (context.knownRegion == nil || context.knownRegion == region)
    }

    static func sameKey(_ lhs: String?, _ rhs: String?) -> Bool {
        // S3 identifies UTF-8 keys literally, without Unicode normalization.
        lhs.map { Data($0.utf8) } == rhs.map { Data($0.utf8) }
    }

    static func validKey(_ key: String) -> Bool { !key.isEmpty && key.utf8.count <= 1_024 }

    static func sameContext(_ lhs: S3TransferContext?, _ rhs: S3TransferContext?) -> Bool {
        lhs == rhs && sameKey(lhs?.bucket, rhs?.bucket) && sameKey(lhs?.prefix, rhs?.prefix)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        sameContext(lhs.context, rhs.context) && sameKey(lhs.key, rhs.key) && lhs.region == rhs.region
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(context)
        hasher.combine(Data(context.bucket.utf8))
        hasher.combine(Data(context.prefix.utf8))
        hasher.combine(Data(key.utf8))
        hasher.combine(region)
    }
}

struct S3ObjectVersion: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case version, deleteMarker }
    let versionID: String
    let kind: Kind
    let isLatest: Bool?
    let lastModified: Date?
    let size: Int64?
    let eTag: String?
    let storageClass: String?
    var id: Data { Data(versionID.utf8) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.isLatest == rhs.isLatest &&
            lhs.lastModified == rhs.lastModified && lhs.size == rhs.size && lhs.eTag == rhs.eTag && lhs.storageClass == rhs.storageClass
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id); hasher.combine(kind); hasher.combine(isLatest)
        hasher.combine(lastModified); hasher.combine(size); hasher.combine(eTag); hasher.combine(storageClass)
    }
}

struct S3VersionsMarker: Hashable, Sendable {
    let key: String
    let versionID: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        S3VersionsTarget.sameKey(lhs.key, rhs.key) && S3VersionsTarget.sameKey(lhs.versionID, rhs.versionID)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(Data(key.utf8))
        hasher.combine(versionID.map { Data($0.utf8) })
    }
}

struct S3VersionsCursor: Hashable, Sendable {
    let target: S3VersionsTarget
    let marker: S3VersionsMarker
    let seenMarkers: Set<S3VersionsMarker>
    let pagesRead: Int
}

struct S3VersionsPage: Sendable {
    let target: S3VersionsTarget
    let versions: [S3ObjectVersion]
    let cursor: S3VersionsCursor?
}

enum S3VersionsError: LocalizedError, Equatable {
    case invalidScope, regionUnavailable, invalidResponse, invalidCursor, incompletePagination, permission, failed
    var errorDescription: String? {
        switch self {
        case .invalidScope: return "Select a verified profile, bucket and object before viewing versions. Directory buckets are not supported."
        case .regionUnavailable: return "Could not determine the bucket region. Check s3:GetBucketLocation permission and retry."
        case .invalidResponse: return "S3 returned incomplete or mismatched version data. Reload to try again."
        case .invalidCursor: return "This version page no longer matches the selected object. Reload versions."
        case .incompletePagination: return "The version pagination limit was reached. Reload or inspect this object in AWS."
        case .permission: return "Version access was denied. Check s3:ListBucketVersions permission and the bucket owner."
        case .failed: return "Unable to read object versions. Check the selected profile, bucket, network and permissions, then retry."
        }
    }
}
