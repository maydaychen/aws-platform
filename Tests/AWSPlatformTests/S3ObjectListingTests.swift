import SotoS3
import XCTest
@testable import AWSPlatform

final class S3ObjectListingTests: XCTestCase {
    func testRequestKeepsOpaqueTokenAndLiteralPrefixWithFixedPageSize() {
        let prefix = "/中文//../a%2Fb + #/"
        let token = "opaque+/=%2F token"
        let request = S3ObjectListing.request(bucket: "example", prefix: prefix, token: token)
        XCTAssertEqual(request.bucket, "example")
        XCTAssertEqual(request.prefix, prefix)
        XCTAssertEqual(request.continuationToken, token)
        XCTAssertEqual(request.delimiter, "/")
        XCTAssertEqual(request.maxKeys, 1_000)
        XCTAssertNil(request.startAfter)
        XCTAssertNil(request.encodingType)
        XCTAssertNil(S3ObjectListing.request(bucket: "example", prefix: "", token: nil).prefix)
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
            contents: [.init(key: "literal%20+中文", lastModified: date, size: 0, storageClass: .standard)],
            isTruncated: false, nextContinuationToken: "ignored"), prefix: "")
        XCTAssertEqual(page.objects.first?.key, "literal%20+中文")
        XCTAssertEqual(page.objects.first?.lastModified, date)
        XCTAssertEqual(page.objects.first?.size, 0)
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

    private func object(_ key: String, size: Int64? = nil, isPrefix: Bool = false) -> S3ObjectModel {
        .init(key: key, size: size, lastModified: nil, storageClass: nil, isPrefix: isPrefix)
    }
}
