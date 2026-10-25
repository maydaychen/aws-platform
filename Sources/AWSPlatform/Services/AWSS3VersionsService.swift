import Foundation
import SotoCore
import SotoS3

struct AWSS3VersionsService: Sendable {
    typealias RegionLoader = @Sendable (S3TransferContext) async throws -> String
    typealias Loader = @Sendable (S3VersionsTarget, S3.ListObjectVersionsRequest) async throws -> S3.ListObjectVersionsOutput
    private let regionLoader: RegionLoader
    private let loader: Loader
    static let pageSize = 100

    init(provider: AWSServiceProvider) {
        regionLoader = { context in
            let client = try await provider.transferS3Client(scope: context.scope, region: context.scope.region)
            try Task.checkCancellation()
            let response = try await client.getBucketLocation(.init(bucket: context.bucket, expectedBucketOwner: context.scope.accountID))
            let raw = response.locationConstraint?.rawValue ?? ""
            return raw.isEmpty ? "us-east-1" : raw == "EU" ? "eu-west-1" : raw
        }
        loader = { target, request in
            let client = try await provider.transferS3Client(scope: target.context.scope, region: target.region)
            try Task.checkCancellation()
            return try await client.listObjectVersions(request)
        }
    }

    init(regionLoader: @escaping RegionLoader, loader: @escaping Loader) {
        self.regionLoader = regionLoader
        self.loader = loader
    }

    func resolve(context: S3TransferContext, key: String) async throws -> S3VersionsTarget {
        do {
            try Task.checkCancellation()
            guard context.isValid, !context.scope.configPath.isEmpty, !context.scope.credentialsPath.isEmpty,
                  !context.bucket.hasSuffix("--x-s3"), key.utf8.starts(with: context.prefix.utf8),
                  S3VersionsTarget.validKey(key) else { throw S3VersionsError.invalidScope }
            let region: String
            if let known = context.knownRegion { region = known }
            else {
                do { region = try await regionLoader(context) }
                catch { try Task.checkCancellation(); throw S3VersionsError.regionUnavailable }
            }
            try Task.checkCancellation()
            let target = S3VersionsTarget(context: context, key: key, region: region)
            guard target.isValid else { throw S3VersionsError.invalidScope }
            return target
        } catch { throw Self.sanitized(error) }
    }

    func load(target: S3VersionsTarget, cursor: S3VersionsCursor?) async throws -> S3VersionsPage {
        do {
            try Task.checkCancellation()
            guard target.isValid else { throw S3VersionsError.invalidScope }
            if let cursor {
                guard cursor.target == target, (1..<1_000).contains(cursor.pagesRead),
                      !cursor.marker.key.isEmpty, cursor.marker.key.utf8.starts(with: target.key.utf8),
                      cursor.marker.versionID == nil || !cursor.marker.versionID!.isEmpty,
                      cursor.seenMarkers.contains(cursor.marker), cursor.seenMarkers.count == cursor.pagesRead else {
                    throw S3VersionsError.invalidCursor
                }
            }
            let response = try await loader(target, .init(bucket: target.context.bucket, encodingType: .url,
                expectedBucketOwner: target.context.scope.accountID, keyMarker: cursor?.marker.key,
                maxKeys: Self.pageSize, prefix: target.key, versionIdMarker: cursor?.marker.versionID))
            try Task.checkCancellation()
            let prefix = try Self.decodeKey(response.prefix, encoding: response.encodingType)
            let keyMarker = try Self.decodeKey(response.keyMarker, encoding: response.encodingType)
            let nextKeyMarker = try Self.decodeKey(response.nextKeyMarker, encoding: response.encodingType)
            guard S3VersionsTarget.sameKey(response.name, target.context.bucket), S3VersionsTarget.sameKey(prefix, target.key),
                  Self.matchesEcho(keyMarker, expected: cursor?.marker.key),
                  Self.matchesEcho(response.versionIdMarker, expected: cursor?.marker.versionID),
                  response.commonPrefixes?.isEmpty != false,
                  (response.versions?.count ?? 0) + (response.deleteMarkers?.count ?? 0) <= Self.pageSize,
                  let truncated = response.isTruncated else { throw S3VersionsError.invalidResponse }
            var values: [S3ObjectVersion] = []
            for raw in response.versions ?? [] {
                guard let key = try Self.decodeKey(raw.key, encoding: response.encodingType),
                      key.utf8.starts(with: target.key.utf8) else { throw S3VersionsError.invalidResponse }
                guard S3VersionsTarget.sameKey(key, target.key) else { continue }
                try Self.validate(versionID: raw.versionId, date: raw.lastModified)
                guard raw.size == nil || raw.size! >= 0 else { throw S3VersionsError.invalidResponse }
                values.append(.init(versionID: raw.versionId!, kind: .version, isLatest: raw.isLatest,
                    lastModified: raw.lastModified, size: raw.size, eTag: raw.eTag, storageClass: raw.storageClass?.rawValue))
            }
            for raw in response.deleteMarkers ?? [] {
                guard let key = try Self.decodeKey(raw.key, encoding: response.encodingType),
                      key.utf8.starts(with: target.key.utf8) else { throw S3VersionsError.invalidResponse }
                guard S3VersionsTarget.sameKey(key, target.key) else { continue }
                try Self.validate(versionID: raw.versionId, date: raw.lastModified)
                values.append(.init(versionID: raw.versionId!, kind: .deleteMarker, isLatest: raw.isLatest,
                    lastModified: raw.lastModified, size: nil, eTag: nil, storageClass: nil))
            }
            guard Set(values.map(\.id)).count == values.count else { throw S3VersionsError.invalidResponse }
            var next: S3VersionsCursor?
            if truncated {
                guard let key = nextKeyMarker, !key.isEmpty, key.utf8.starts(with: target.key.utf8),
                      response.nextVersionIdMarker == nil || !response.nextVersionIdMarker!.isEmpty else {
                    throw S3VersionsError.incompletePagination
                }
                let marker = S3VersionsMarker(key: key, versionID: response.nextVersionIdMarker)
                var seen = cursor?.seenMarkers ?? []
                let pages = (cursor?.pagesRead ?? 0) + 1
                guard seen.insert(marker).inserted, pages < 1_000 else { throw S3VersionsError.incompletePagination }
                next = .init(target: target, marker: marker, seenMarkers: seen, pagesRead: pages)
            } else if nextKeyMarker != nil || response.nextVersionIdMarker != nil {
                throw S3VersionsError.invalidResponse
            }
            return .init(target: target, versions: Self.sorted(values), cursor: next)
        } catch { throw Self.sanitized(error) }
    }

    static func sorted(_ values: some Sequence<S3ObjectVersion>) -> [S3ObjectVersion] {
        values.sorted {
            if $0.lastModified != $1.lastModified { return ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
            return $0.id.lexicographicallyPrecedes($1.id)
        }
    }

    private static func matchesEcho(_ actual: String?, expected: String?) -> Bool {
        if let expected { return S3VersionsTarget.sameKey(actual, expected) }
        return actual == nil || actual?.isEmpty == true
    }

    private static func decodeKey(_ value: String?, encoding: S3.EncodingType?) throws -> String? {
        // EncodingType applies to key fields, not version IDs or version-ID markers.
        guard let value, encoding == .url else { return value }
        let encoded = Array(value.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(encoded.count)
        var index = 0
        while index < encoded.count {
            if encoded[index] == 0x25 {
                guard index + 2 < encoded.count, let high = hex(encoded[index + 1]), let low = hex(encoded[index + 2]) else {
                    throw S3VersionsError.invalidResponse
                }
                decoded.append(high * 16 + low)
                index += 3
            } else {
                decoded.append(encoded[index])
                index += 1
            }
        }
        guard let result = String(bytes: decoded, encoding: .utf8) else { throw S3VersionsError.invalidResponse }
        return result
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }

    private static func validate(versionID: String?, date: Date?) throws {
        guard let versionID, !versionID.isEmpty,
              !versionID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              date == nil || (date!.timeIntervalSince1970.isFinite && date!.timeIntervalSince1970 >= 0) else {
            throw S3VersionsError.invalidResponse
        }
    }

    static func sanitized(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if let error = error as? S3VersionsError { return error }
        if error is AWSServiceError { return S3VersionsError.invalidScope }
        let code = AWSS3TransferService.code(error) ?? ""
        if ["AccessDenied", "Forbidden", "403"].contains(code) { return S3VersionsError.permission }
        return S3VersionsError.failed
    }
}
