import Foundation

struct S3TransferContext: Hashable, Sendable {
    let scope: MonitoringScope
    let bucket: String
    let prefix: String
    let knownRegion: String?

    var isValid: Bool {
        scope.isValid && !bucket.isEmpty && !bucket.contains("/") &&
        !bucket.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    func key(filename: String) throws -> String {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"),
              !filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw S3TransferError.invalidFilename }
        let key = prefix + filename
        try S3TransferTarget.validateKey(key)
        return key
    }
}

struct S3TransferTarget: Hashable, Sendable {
    let context: S3TransferContext
    let key: String
    let region: String

    static func validateKey(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 1024,
              !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw S3TransferError.invalidFilename }
    }
}

struct S3UploadIntent: Identifiable, Hashable, Sendable {
    let id = UUID()
    let context: S3TransferContext
    let file: S3LocalFile
    let key: String
    var overwriteETag: String?
    var resolvedRegion: String?
}

struct S3TransferProgress: Sendable {
    let bytes: Int64
    let total: Int64?
    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(bytes) / Double(total))
    }
}

enum S3TransferError: Error, Equatable, LocalizedError {
    case invalidScope, invalidFilename, invalidFile, fileChanged, tooLarge
    case regionUnavailable, destinationChanged, incompleteDownload
    case objectExists(etag: String, region: String)
    case objectChanged, accessDenied, archivedObject, notFound, failed

    var errorDescription: String? {
        switch self {
        case .invalidScope: return "Select and verify a Profile before transferring files."
        case .invalidFilename: return "Use a valid filename. The full S3 key must fit within 1,024 UTF-8 bytes."
        case .invalidFile: return "Choose a readable regular file. Folders and symbolic links are not supported."
        case .fileChanged: return "The local file changed. Choose it again before uploading."
        case .tooLarge: return "Single-file uploads are limited to 5 GiB."
        case .regionUnavailable: return "Could not determine the Bucket region. Check s3:GetBucketLocation permission and retry."
        case .destinationChanged: return "The local destination changed. Choose a save location again."
        case .incompleteDownload: return "The download was incomplete. The original local file was preserved."
        case .objectExists: return "An object with this key already exists. Confirm before overwriting it."
        case .objectChanged: return "The S3 object changed during upload. Review it and start again."
        case .accessDenied: return "S3 denied this transfer. Check s3:PutObject or s3:GetObject and any required KMS permissions."
        case .archivedObject: return "This object is archived. Restore it in AWS before downloading."
        case .notFound: return "The Bucket or object no longer exists. Refresh and try again."
        case .failed: return "The transfer failed. Check your connection, credentials and local file permissions, then retry."
        }
    }
}

typealias S3ProgressHandler = @Sendable (S3TransferProgress) async -> Void
