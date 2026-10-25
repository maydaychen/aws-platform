import Foundation
import SotoS3

enum S3ObjectListing {
    static let pageSize = 1_000

    static func request(bucket: String, prefix: String, token: String?, accountID: String) -> S3.ListObjectsV2Request {
        .init(bucket: bucket, continuationToken: token, delimiter: "/", expectedBucketOwner: accountID, maxKeys: pageSize,
              prefix: prefix.isEmpty ? nil : prefix)
    }

    static func page(from response: S3.ListObjectsV2Output, prefix: String) throws -> S3ObjectPage {
        let nextToken: String?
        if response.isTruncated == true {
            guard let token = response.nextContinuationToken, !token.isEmpty else {
                throw S3PaginationError.invalidContinuation
            }
            nextToken = token
        } else {
            nextToken = nil
        }
        var rows: [S3ObjectModel] = []
        for entry in response.commonPrefixes ?? [] {
            guard let key = entry.prefix, Data(key.utf8) != Data(prefix.utf8) else { continue }
            rows.append(.init(key: key, size: nil, lastModified: nil, storageClass: nil, isPrefix: true))
        }
        for object in response.contents ?? [] {
            guard let key = object.key, Data(key.utf8) != Data(prefix.utf8) else { continue }
            rows.append(.init(key: key, size: object.size, lastModified: object.lastModified,
                              storageClass: object.storageClass?.rawValue, isPrefix: false, eTag: object.eTag))
        }
        return .init(objects: rows, nextContinuationToken: nextToken)
    }

    static func merge(_ existing: [S3ObjectModel], with page: [S3ObjectModel]) -> [S3ObjectModel] {
        var rows: [Data: S3ObjectModel] = [:]
        for batch in [existing, page] {
            for object in batch {
                // A folder marker must not replace a navigable common prefix with the same key.
                if rows[object.id]?.isPrefix == true, !object.isPrefix { continue }
                rows[object.id] = object
            }
        }
        return rows.values.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    }

    /// `existing` must already have unique keys in UTF-8 byte order, as returned by this method.
    /// Only the incoming page needs sorting; historical rows retain their established order.
    static func mergeSorted(_ existing: [S3ObjectModel], with page: [S3ObjectModel]) -> [S3ObjectModel] {
        mergeSorted(existing, with: page, checkCancellation: {})
    }

    static func mergeSorted(
        _ existing: [S3ObjectModel], with page: [S3ObjectModel],
        checkCancellation: () throws -> Void
    ) rethrows -> [S3ObjectModel] {
        try checkCancellation()
        let incoming = merge([], with: page)
        try checkCancellation()
        guard !existing.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return existing }
        if existing[existing.count - 1].key.utf8.lexicographicallyPrecedes(incoming[0].key.utf8) {
            let result = existing + incoming
            try checkCancellation()
            return result
        }
        if incoming[incoming.count - 1].key.utf8.lexicographicallyPrecedes(existing[0].key.utf8) {
            let result = incoming + existing
            try checkCancellation()
            return result
        }

        var result: [S3ObjectModel] = []
        result.reserveCapacity(existing.count + incoming.count)
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < existing.count && newIndex < incoming.count {
            if result.count.isMultiple(of: 256) { try checkCancellation() }
            let old = existing[oldIndex]
            let new = incoming[newIndex]
            if old.key.utf8.elementsEqual(new.key.utf8) {
                result.append(old.isPrefix && !new.isPrefix ? old : new)
                oldIndex += 1
                newIndex += 1
            } else if old.key.utf8.lexicographicallyPrecedes(new.key.utf8) {
                result.append(old)
                oldIndex += 1
            } else {
                result.append(new)
                newIndex += 1
            }
        }
        try checkCancellation()
        result.append(contentsOf: existing[oldIndex...])
        result.append(contentsOf: incoming[newIndex...])
        try checkCancellation()
        return result
    }

    static func mergeSortedInBackground(
        _ existing: [S3ObjectModel], with page: [S3ObjectModel]
    ) async throws -> [S3ObjectModel] {
        let task = Task.detached(priority: .userInitiated) {
            try mergeSorted(existing, with: page) { try Task.checkCancellation() }
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            task.cancel()
        }
    }
}
