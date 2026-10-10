import Foundation
import SotoS3

enum S3ObjectListing {
    static let pageSize = 1_000

    static func request(bucket: String, prefix: String, token: String?) -> S3.ListObjectsV2Request {
        .init(bucket: bucket, continuationToken: token, delimiter: "/", maxKeys: pageSize,
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
                              storageClass: object.storageClass?.rawValue, isPrefix: false))
        }
        return .init(objects: rows, nextContinuationToken: nextToken)
    }

    static func merge(_ existing: [S3ObjectModel], with page: [S3ObjectModel]) -> [S3ObjectModel] {
        var rows: [Data: S3ObjectModel] = [:]
        for object in existing + page {
            // A folder marker must not replace a navigable common prefix with the same key.
            if rows[object.id]?.isPrefix == true, !object.isPrefix { continue }
            rows[object.id] = object
        }
        return rows.values.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    }
}
