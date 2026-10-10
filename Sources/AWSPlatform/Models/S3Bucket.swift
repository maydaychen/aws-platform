import Foundation

struct S3BucketModel: Identifiable, Hashable {
    let name: String
    var region: String?
    let creationDate: Date?
    var versioningEnabled: Bool?
    var encryptionEnabled: Bool?
    var publicAccessBlock: S3PublicAccessBlockModel?
    var tags: [String: String]
    var detailError: String?

    var id: String { name }
}

struct S3PublicAccessBlockModel: Hashable {
    let blockPublicACLs: Bool
    let ignorePublicACLs: Bool
    let blockPublicPolicy: Bool
    let restrictPublicBuckets: Bool
}

struct S3ObjectModel: Identifiable, Hashable {
    let key: String
    let size: Int64?
    let lastModified: Date?
    let storageClass: String?
    let isPrefix: Bool

    var id: Data { Data(key.utf8) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.size == rhs.size && lhs.lastModified == rhs.lastModified
            && lhs.storageClass == rhs.storageClass && lhs.isPrefix == rhs.isPrefix
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(size)
        hasher.combine(lastModified)
        hasher.combine(storageClass)
        hasher.combine(isPrefix)
    }
}
