import Foundation
import SotoCore
import SotoS3
import UniformTypeIdentifiers

struct AWSS3TransferService: Sendable {
    typealias RegionLoader = @Sendable (S3TransferContext) async throws -> String
    typealias Put = @Sendable (S3TransferTarget, S3.PutObjectRequest) async throws -> Void
    typealias Head = @Sendable (S3TransferTarget, S3.HeadObjectRequest) async throws -> S3.HeadObjectOutput
    typealias Get = @Sendable (S3TransferTarget, S3.GetObjectRequest) async throws -> S3.GetObjectOutput

    private let regionLoader: RegionLoader
    private let put: Put
    private let head: Head
    private let get: Get

    init(provider: AWSServiceProvider) {
        regionLoader = { context in
            let client = try await provider.transferS3Client(scope: context.scope, region: context.scope.region)
            try Task.checkCancellation()
            let result = try await client.getBucketLocation(.init(
                bucket: context.bucket, expectedBucketOwner: context.scope.accountID
            ))
            let region = result.locationConstraint?.rawValue ?? ""
            return region.isEmpty ? "us-east-1" : region == "EU" ? "eu-west-1" : region
        }
        put = { target, request in
            let client = try await provider.transferS3Client(scope: target.context.scope, region: target.region)
            try Task.checkCancellation()
            _ = try await client.putObject(request)
        }
        head = { target, request in
            let client = try await provider.transferS3Client(scope: target.context.scope, region: target.region)
            try Task.checkCancellation()
            return try await client.headObject(request)
        }
        get = { target, request in
            let client = try await provider.transferS3Client(scope: target.context.scope, region: target.region)
            try Task.checkCancellation()
            return try await client.getObject(request)
        }
    }

    init(regionLoader: @escaping RegionLoader, put: @escaping Put, head: @escaping Head, get: @escaping Get) {
        self.regionLoader = regionLoader
        self.put = put
        self.head = head
        self.get = get
    }

    func upload(_ intent: S3UploadIntent, progress: @escaping S3ProgressHandler) async throws {
        guard let checksum = intent.file.checksumSHA256 else { throw S3TransferError.fileChanged }
        let target = try await target(context: intent.context, key: intent.key, region: intent.resolvedRegion)
        let reader = try S3UploadReader(file: intent.file, progress: progress)
        do {
            try Task.checkCancellation()
            let request = S3.PutObjectRequest(
                body: .init(asyncSequence: S3UploadReader.Chunks(reader: reader), length: Int(intent.file.size)),
                bucket: target.context.bucket, checksumAlgorithm: .sha256, checksumSHA256: checksum, contentLength: intent.file.size,
                contentType: UTType(filenameExtension: intent.file.url.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
                expectedBucketOwner: target.context.scope.accountID,
                ifMatch: intent.overwriteETag, ifNoneMatch: intent.overwriteETag == nil ? "*" : nil,
                key: target.key
            )
            try await put(target, request)
            try Task.checkCancellation()
            try await reader.validate()
            await reader.close()
        } catch {
            await reader.close()
            try Task.checkCancellation()
            if Self.code(error) == "PreconditionFailed", intent.overwriteETag == nil {
                do {
                    let existing = try await head(target, .init(
                        bucket: target.context.bucket, expectedBucketOwner: target.context.scope.accountID, key: target.key
                    ))
                    try Task.checkCancellation()
                    guard let etag = existing.eTag, !etag.isEmpty else { throw S3TransferError.objectChanged }
                    throw S3TransferError.objectExists(etag: etag, region: target.region)
                } catch { throw Self.map(error) }
            }
            throw Self.map(error)
        }
    }

    @discardableResult
    func download(context: S3TransferContext, object: S3ObjectModel, destination: S3DownloadDestination,
                  progress: @escaping S3ProgressHandler) async throws -> S3DownloadResult {
        guard !object.isPrefix, let size = object.size, size >= 0,
              let etag = object.eTag, !etag.isEmpty else { throw S3TransferError.objectChanged }
        let key = object.key
        let target = try await target(context: context, key: key)
        let writer = try S3DownloadWriter(destination: destination, expectedLength: size)
        defer { writer.cleanup() }
        do {
            let response = try await get(target, .init(
                bucket: context.bucket, expectedBucketOwner: context.scope.accountID, ifMatch: etag, key: key
            ))
            try Task.checkCancellation()
            guard response.contentLength == size, response.eTag == etag else {
                throw S3TransferError.objectChanged
            }
            for try await buffer in response.body {
                try writer.write(Data(buffer.readableBytesView))
                await progress(.init(bytes: writer.bytes, total: response.contentLength))
            }
            return try writer.commit(expectedLength: size)
        } catch {
            try Task.checkCancellation()
            throw Self.map(error)
        }
    }

    private func target(context: S3TransferContext, key: String, region: String? = nil) async throws -> S3TransferTarget {
        try Task.checkCancellation()
        guard context.isValid else { throw S3TransferError.invalidScope }
        try S3TransferTarget.validateKey(key)
        let resolved: String
        if let known = region ?? context.knownRegion {
            resolved = known
        } else {
            do { resolved = try await regionLoader(context) }
            catch {
                try Task.checkCancellation()
                throw S3TransferError.regionUnavailable
            }
        }
        try Task.checkCancellation()
        // Reuse scope validation to check region syntax and AWS partition.
        let regionalScope = MonitoringScope(profile: context.scope.profile,
            identity: .init(account: context.scope.accountID, arn: context.scope.principalARN, userID: ""),
            region: resolved, paths: context.scope.paths)
        guard regionalScope.isValid else { throw S3TransferError.regionUnavailable }
        return .init(context: context, key: key, region: resolved)
    }

    static func code(_ error: Error) -> String? {
        if let code = (error as? AWSErrorType)?.errorCode { return code }
        // HeadObject can return only an HTTP status, without an XML error code.
        switch (error as? AWSRawError)?.context.responseCode.code {
        case 403: return "AccessDenied"
        case 404: return "NotFound"
        case 412: return "PreconditionFailed"
        case 409: return "ConditionalRequestConflict"
        default: return nil
        }
    }

    static func map(_ error: Error) -> Error {
        if error is CancellationError || error is S3TransferError { return error }
        switch code(error) {
        case "PreconditionFailed", "ConditionalRequestConflict": return S3TransferError.objectChanged
        case "AccessDenied", "Forbidden", "403": return S3TransferError.accessDenied
        case "InvalidObjectState": return S3TransferError.archivedObject
        case "BadDigest", "InvalidDigest": return S3TransferError.fileChanged
        case "NoSuchBucket", "NoSuchKey", "NotFound", "404": return S3TransferError.notFound
        default: return S3TransferError.failed
        }
    }
}
