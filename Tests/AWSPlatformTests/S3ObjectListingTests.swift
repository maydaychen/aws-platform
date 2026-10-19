import SotoS3
import XCTest
@testable import AWSPlatform

final class S3ObjectListingTests: XCTestCase {
    func testRequestKeepsOpaqueTokenAndLiteralPrefixWithFixedPageSize() {
        let prefix = "/中文//../a%2Fb + #/"
        let token = "opaque+/=%2F token"
        let request = S3ObjectListing.request(bucket: "example", prefix: prefix, token: token, accountID: "111122223333")
        XCTAssertEqual(request.bucket, "example")
        XCTAssertEqual(request.expectedBucketOwner, "111122223333")
        XCTAssertEqual(request.prefix, prefix)
        XCTAssertEqual(request.continuationToken, token)
        XCTAssertEqual(request.delimiter, "/")
        XCTAssertEqual(request.maxKeys, 1_000)
        XCTAssertNil(request.startAfter)
        XCTAssertNil(request.encodingType)
        XCTAssertNil(S3ObjectListing.request(bucket: "example", prefix: "", token: nil, accountID: "111122223333").prefix)
    }

    func testFolderOnlyAndFilteredMarkerPagesStillHaveMore() throws {
        let folderPage = try S3ObjectListing.page(from: .init(
            commonPrefixes: [.init(prefix: "parent/子目录/")], isTruncated: true,
            nextContinuationToken: "next"), prefix: "parent/")
        XCTAssertEqual(folderPage.objects.map(\.key), ["parent/子目录/"])
        XCTAssertTrue(folderPage.objects[0].isPrefix)
        XCTAssertEqual(folderPage.nextContinuationToken, "next")

        let emptyPage = try S3ObjectListing.page(from: .init(
            contents: [.init(key: "parent/", size: 0)], isTruncated: true,
            nextContinuationToken: "more"), prefix: "parent/")
        XCTAssertTrue(emptyPage.objects.isEmpty)
        XCTAssertEqual(emptyPage.nextContinuationToken, "more")
    }

    func testFinalAndEmptyPagesDoNotInventAContinuation() throws {
        let date = Date(timeIntervalSince1970: 100)
        let page = try S3ObjectListing.page(from: .init(
            contents: [.init(eTag: "listed-etag", key: "literal%20+中文", lastModified: date, size: 0, storageClass: .standard)],
            isTruncated: false, nextContinuationToken: "ignored"), prefix: "")
        XCTAssertEqual(page.objects.first?.key, "literal%20+中文")
        XCTAssertEqual(page.objects.first?.lastModified, date)
        XCTAssertEqual(page.objects.first?.size, 0)
        XCTAssertEqual(page.objects.first?.eTag, "listed-etag")
        XCTAssertEqual(page.objects.first?.storageClass, "STANDARD")
        XCTAssertNil(page.nextContinuationToken)
        XCTAssertTrue(try S3ObjectListing.page(from: .init(isTruncated: false), prefix: "").objects.isEmpty)
    }

    func testTruncatedResponseRequiresUsableToken() {
        for token in [nil, ""] as [String?] {
            XCTAssertThrowsError(try S3ObjectListing.page(from: .init(isTruncated: true, nextContinuationToken: token), prefix: ""))
        }
    }

    func testMergeDeduplicatesKeysUpdatesMetadataAndKeepsFoldersNavigable() {
        let folder = object("folder/", isPrefix: true)
        let old = object("a", size: 1)
        let fresh = object("a", size: 2)
        let result = S3ObjectListing.merge([old, folder], with: [object("z"), fresh, object("folder/", size: 0), folder])
        XCTAssertEqual(result.map(\.key), ["a", "folder/", "z"])
        XCTAssertEqual(result.first?.size, 2)
        XCTAssertTrue(result[1].isPrefix)
    }

    func testByteDistinctUnicodeKeysKeepSeparateIdentityAndMetadata() {
        let composed = object("caf\u{e9}", size: 1)
        let decomposed = object("cafe\u{301}", size: 1)
        XCTAssertEqual(composed.key, decomposed.key, "Swift String equality normalizes Unicode")
        XCTAssertNotEqual(composed.id, decomposed.id)
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(Set([composed, decomposed]).count, 2)
        let result = S3ObjectListing.merge([composed], with: [decomposed, object(composed.key, size: 2)])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map { Data($0.key.utf8) }, [Data(decomposed.key.utf8), Data(composed.key.utf8)])
        XCTAssertEqual(result.map(\.size), [1, 2])
    }

    func testCompatibilityMergeAcceptsUnsortedAndRepeatedHistoricalKeys() {
        let result = S3ObjectListing.merge(
            [object("z", size: 1), object("a", size: 1), object("z", size: 2), object("folder/", isPrefix: true)],
            with: [object("folder/", size: 0), object("a", size: 3)]
        )
        XCTAssertEqual(result.map(\.key), ["a", "folder/", "z"])
        XCTAssertEqual(result.map(\.size), [3, nil, 2])
        XCTAssertTrue(result[1].isPrefix)
    }

    func testOrderedMergeMatchesCompatibilityAcrossOverlapsEmptyPagesAndLiteralKeys() {
        let pages: [[S3ObjectModel]] = [
            [object("z", size: 1), object("caf\u{e9}", size: 1), object("folder/", isPrefix: true)],
            [object("a", size: 1), object("cafe\u{301}", size: 2), object("z", size: 2)],
            [],
            [object("folder/", size: 0), object("literal%2F+ #/中文", size: 3), object("a", size: 4)],
            [object("0", size: 1), object("0", size: 2), object("a", isPrefix: true), object("a", size: 9)],
            [object("zz", size: 5)]
        ]
        var ordered: [S3ObjectModel] = []
        var reference: [S3ObjectModel] = []
        for page in pages {
            ordered = S3ObjectListing.mergeSorted(ordered, with: page)
            reference = S3ObjectListing.merge(reference, with: page)
            XCTAssertEqual(ordered, reference)
        }
        XCTAssertTrue(ordered.first(where: { $0.key == "a" })?.isPrefix == true)
        XCTAssertEqual(ordered.first(where: { $0.key == "0" })?.size, 2)
        XCTAssertEqual(ordered.filter { $0.key == "café" }.count, 2)
    }

    func testOrderedMergeMatchesCompatibilityAcrossManyInterleavedPages() {
        var ordered: [S3ObjectModel] = []
        var reference: [S3ObjectModel] = []
        for pageIndex in 0..<20 {
            let page = (0..<100).reversed().map { index in
                object("key-\((index * 17 + pageIndex * 13) % 257)", size: Int64(pageIndex * 100 + index),
                       isPrefix: (index + pageIndex).isMultiple(of: 11))
            }
            ordered = S3ObjectListing.mergeSorted(ordered, with: page)
            reference = S3ObjectListing.merge(reference, with: page)
            XCTAssertEqual(ordered, reference)
        }
    }

    func testOrderedMergeChecksCancellationDuringLargeInterleavedMerge() {
        let existing = (0..<2_000).map { object(String(format: "key-%05d", $0 * 2)) }
        let page = (0..<1_000).map { object(String(format: "key-%05d", $0 * 2 + 1)) }
        var checks = 0
        XCTAssertThrowsError(try S3ObjectListing.mergeSorted(existing, with: page) {
            checks += 1
            if checks == 5 { throw CancellationError() }
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checks, 5)
    }

    func testCancelledBackgroundMergeDoesNotReturnRows() async {
        let page = [object("file")]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await S3ObjectListing.mergeSortedInBackground([], with: page)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled merge must not return a usable result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func object(_ key: String, size: Int64? = nil, isPrefix: Bool = false) -> S3ObjectModel {
        .init(key: key, size: size, lastModified: nil, storageClass: nil, isPrefix: isPrefix)
    }
}
