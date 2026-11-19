import Foundation
import SotoS3

enum S3BucketListing {
    typealias PageLoader = @Sendable (S3.ListBucketsRequest) async throws -> S3.ListBucketsOutput
    static let pageSize = 1_000
    static let maximumPages = 1_000

    static func load(scope: MonitoringScope, pageLoader: PageLoader) async throws -> [S3BucketModel] {
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
                buckets.append(.init(name: name, region: S3BucketRegion.validated(bucket.bucketRegion, in: scope),
                    creationDate: bucket.creationDate,
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

enum S3BucketRegion {
    static func validated(_ raw: String?, in scope: MonitoringScope) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let region = raw == "EU" ? "eu-west-1" : raw
        return scope.replacingRegion(region).isValid ? region : nil
    }

    static func fromLocation(_ raw: String?) -> String {
        // An empty LocationConstraint denotes us-east-1, unlike an absent ListBuckets hint.
        guard let raw, !raw.isEmpty else { return "us-east-1" }
        return raw
    }
}
