import SotoS3
import XCTest
@testable import AWSPlatform

final class S3BucketListingTests: XCTestCase {
    func testPaginationRequestsEveryPageWithoutRegionOrPrefixFiltering() async throws {
        let probe = BucketPageProbe()
        let buckets = try await S3BucketListing.load { request in
            await probe.record(request)
            if request.continuationToken == nil {
                return .init(buckets: [.init(creationDate: Date(timeIntervalSince1970: 12), name: "first")],
                             continuationToken: "opaque+/=% token")
            }
            return .init(buckets: [.init(name: "second")])
        }
        XCTAssertEqual(buckets.map(\.name), ["first", "second"])
        XCTAssertEqual(buckets.first?.creationDate, Date(timeIntervalSince1970: 12))
        let requests = await probe.requests
        XCTAssertEqual(requests.map(\.continuationToken), [nil, "opaque+/=% token"])
        XCTAssertTrue(requests.allSatisfy { $0.maxBuckets == 1_000 && $0.prefix == nil && $0.bucketRegion == nil })
    }

    func testEmptyPageStillConsumesContinuation() async throws {
        let buckets = try await S3BucketListing.load { request in
            request.continuationToken == nil ? .init(buckets: [], continuationToken: "next")
                : .init(buckets: [.init(name: "after-empty")])
        }
        XCTAssertEqual(buckets.map(\.name), ["after-empty"])
        let empty = try await S3BucketListing.load { _ in .init(buckets: []) }
        XCTAssertTrue(empty.isEmpty)
    }

    func testRepeatedAndWhitespaceTokensNeverReturnPartialResults() async {
        for token in ["loop", " "] {
            do {
                _ = try await S3BucketListing.load { _ in .init(buckets: [], continuationToken: token) }
                XCTFail("Invalid pagination must fail")
            } catch {
                XCTAssertEqual(error as? S3BucketListing.ListingError, .incompletePagination)
            }
        }
    }

    func testLaterPageFailurePropagatesInsteadOfReturningFirstPage() async {
        do {
            _ = try await S3BucketListing.load { request in
                if request.continuationToken != nil { throw BucketPageError.failed }
                return .init(buckets: [.init(name: "partial")], continuationToken: "next")
            }
            XCTFail("A partial list must not be successful")
        } catch { XCTAssertTrue(error is BucketPageError) }
    }

    func testDuplicateAndMissingBucketNamesAreRejected() async {
        for rows in [[S3.Bucket()], [.init(name: " ")], [.init(name: "same"), .init(name: "same")]] {
            do {
                _ = try await S3BucketListing.load { _ in .init(buckets: rows) }
                XCTFail("Malformed bucket response must fail")
            } catch { XCTAssertEqual(error as? S3BucketListing.ListingError, .invalidResponse) }
        }
        do {
            _ = try await S3BucketListing.load { request in
                .init(buckets: [.init(name: "same")], continuationToken: request.continuationToken == nil ? "next" : nil)
            }
            XCTFail("Duplicate bucket across pages must fail")
        } catch { XCTAssertEqual(error as? S3BucketListing.ListingError, .invalidResponse) }
    }

    func testPageBudgetStopsUnboundedPagination() async {
        let probe = BucketPageProbe()
        do {
            _ = try await S3BucketListing.load { request in
                let count = await probe.record(request)
                return .init(buckets: [], continuationToken: "next-\(count)")
            }
            XCTFail("Unbounded pagination must fail")
        } catch { XCTAssertEqual(error as? S3BucketListing.ListingError, .incompletePagination) }
        let count = await probe.requests.count
        XCTAssertEqual(count, S3BucketListing.maximumPages)
    }

    func testCancelledResponseCannotFetchNextPageOrReturnResults() async {
        let gate = TestGate()
        let probe = BucketPageProbe()
        let task = Task {
            try await S3BucketListing.load { request in
                await probe.record(request)
                await gate.wait()
                return .init(buckets: [.init(name: "stale")], continuationToken: "must-not-fetch")
            }
        }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Cancelled response must be discarded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await probe.requests.count
        XCTAssertEqual(count, 1)
    }
}

private actor BucketPageProbe {
    private(set) var requests: [S3.ListBucketsRequest] = []
    @discardableResult
    func record(_ request: S3.ListBucketsRequest) -> Int {
        requests.append(request)
        return requests.count
    }
}

private enum BucketPageError: Error { case failed }
