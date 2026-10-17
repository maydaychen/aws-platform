import Foundation
import SotoS3

enum S3BucketListing {
    typealias PageLoader = @Sendable (S3.ListBucketsRequest) async throws -> S3.ListBucketsOutput
    static let pageSize = 1_000
    static let maximumPages = 1_000

    static func load(pageLoader: PageLoader) async throws -> [S3BucketModel] {
        var buckets: [S3BucketModel] = []
        var names: Set<String> = []
        var tokens: Set<Data> = []
        var token: String?
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            // Pagination is mandatory for accounts whose approved bucket quota exceeds 10,000.
            let page = try await pageLoader(.init(continuationToken: token, maxBuckets: pageSize))
            try Task.checkCancellation()
            for bucket in page.buckets ?? [] {
                guard let name = bucket.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      names.insert(name).inserted else { throw ListingError.invalidResponse }
                buckets.append(.init(name: name, region: nil, creationDate: bucket.creationDate,
                    versioningEnabled: nil, encryptionEnabled: nil, publicAccessBlock: nil,
                    tags: [:], detailError: nil))
            }
            guard let next = page.continuationToken, !next.isEmpty else { return buckets }
            guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  tokens.insert(Data(next.utf8)).inserted else { throw ListingError.incompletePagination }
            token = next
        }
        throw ListingError.incompletePagination
    }

    enum ListingError: LocalizedError, Equatable {
        case invalidResponse, incompletePagination

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "S3 returned an invalid bucket list. Refresh to try again."
            case .incompletePagination:
                return "S3 could not complete the bucket list. Refresh to try again."
            }
        }
    }
}
