import Foundation
import SotoS3
import XCTest
@testable import AWSPlatform

final class AWSS3VersionsServiceTests: XCTestCase {
    func testRequestUsesVerifiedOwnerExactPrefixAndActualBucketRegion() async throws {
        let target = versionsTarget()
        let fixture = S3VersionsFixture(pages: [.init(isTruncated: false, name: target.context.bucket, prefix: target.key,
            versions: [.init(eTag: "etag", isLatest: true, key: target.key, size: 42, versionId: "v1")])])
        let page = try await fixture.service.load(target: target, cursor: nil)
        XCTAssertEqual(page.versions.count, 1)
        XCTAssertEqual(page.versions[0].size, 42)
        let inputs = await fixture.inputs
        XCTAssertEqual(inputs[0].bucket, target.context.bucket)
        XCTAssertEqual(inputs[0].expectedBucketOwner, target.context.scope.accountID)
        XCTAssertEqual(inputs[0].prefix, target.key)
        XCTAssertEqual(inputs[0].maxKeys, 100)
        XCTAssertEqual(inputs[0].encodingType, .url)
        XCTAssertNil(inputs[0].delimiter)
        let targets = await fixture.targets
        XCTAssertEqual(targets[0].region, "eu-west-1")
    }

    func testVersionsAndDeleteMarkersAreDistinctAndOptionalFieldsRemainUnknown() async throws {
        let target = versionsTarget()
        let fixture = S3VersionsFixture(pages: [.init(deleteMarkers: [.init(key: target.key, versionId: "deleted")],
            isTruncated: false, name: target.context.bucket, prefix: target.key,
            versions: [.init(key: target.key, versionId: "null")])])
        let page = try await fixture.service.load(target: target, cursor: nil)
        XCTAssertEqual(Set(page.versions.map(\.kind)), [.version, .deleteMarker])
        XCTAssertTrue(page.versions.allSatisfy { $0.isLatest == nil && $0.size == nil && $0.lastModified == nil })
        XCTAssertTrue(page.versions.contains { $0.versionID == "null" })
    }

    func testPrefixNeighboursAreNotMixedIntoExactObjectVersions() async throws {
        let target = versionsTarget()
        let fixture = S3VersionsFixture(pages: [.init(deleteMarkers: [.init(key: target.key + "/child", versionId: "child-delete")],
            isTruncated: false, name: target.context.bucket, prefix: target.key,
            versions: [.init(key: target.key, versionId: "exact"), .init(key: target.key + ".bak", versionId: "suffix")])])
        let page = try await fixture.service.load(target: target, cursor: nil)
        XCTAssertEqual(page.versions.map(\.versionID), ["exact"])
    }

    func testMissingRegionResolvesOnceAndKnownRegionSkipsResolution() async throws {
        let fixture = S3VersionsFixture()
        let unknown = versionsContext(region: nil)
        let resolved = try await fixture.service.resolve(context: unknown, key: "reports/summary.csv")
        XCTAssertEqual(resolved.region, "eu-west-1")
        _ = try await fixture.service.resolve(context: versionsContext(), key: "reports/summary.csv")
        let contexts = await fixture.regionContexts
        XCTAssertEqual(contexts, [unknown])
    }

    func testRegionMustMatchPartitionAndKnownRegion() async {
        let fixture = S3VersionsFixture(region: "cn-north-1")
        await assertError(.invalidScope) { _ = try await fixture.service.resolve(context: versionsContext(region: nil), key: "reports/summary.csv") }
        let mismatched = S3VersionsTarget(context: versionsContext(), key: "reports/summary.csv", region: "us-east-1")
        await assertError(.invalidScope) { _ = try await fixture.service.load(target: mismatched, cursor: nil) }
        let count = await fixture.inputs.count
        XCTAssertEqual(count, 0)
    }

    func testInvalidIdentityIsRejectedBeforeRegionLookup() async {
        let fixture = S3VersionsFixture()
        let context = versionsContext(region: nil, scope: logsVersionsScope(account: "invalid"))
        await assertError(.invalidScope) { _ = try await fixture.service.resolve(context: context, key: "reports/summary.csv") }
        let count = await fixture.regionContexts.count
        XCTAssertEqual(count, 0)
    }

    func testInvalidKeysAndDirectoryBucketsCannotRequestVersions() async {
        let fixture = S3VersionsFixture()
        for key in ["", "other/report", "reports/" + String(repeating: "x", count: 1_025)] {
            await assertError(.invalidScope) { _ = try await fixture.service.resolve(context: versionsContext(), key: key) }
        }
        let directory = S3TransferContext(scope: logsVersionsScope(), bucket: "bucket--zone--x-s3", prefix: "", knownRegion: "eu-west-1")
        await assertError(.invalidScope) { _ = try await fixture.service.resolve(context: directory, key: "key") }
    }

    func testBothPaginationMarkersTravelTogetherAndBindFullTarget() async throws {
        let target = versionsTarget()
        let fixture = S3VersionsFixture(pages: [
            .init(isTruncated: true, name: target.context.bucket, nextKeyMarker: target.key, nextVersionIdMarker: "v1", prefix: target.key),
            .init(isTruncated: false, keyMarker: target.key, name: target.context.bucket, prefix: target.key, versionIdMarker: "v1")
        ])
        let first = try await fixture.service.load(target: target, cursor: nil)
        let second = try await fixture.service.load(target: target, cursor: first.cursor)
        XCTAssertNil(second.cursor)
        let inputs = await fixture.inputs
        XCTAssertEqual(inputs.map(\.keyMarker), [nil, target.key])
        XCTAssertEqual(inputs.map(\.versionIdMarker), [nil, "v1"])
        let other = versionsTarget(context: versionsContext(scope: logsVersionsScope(profile: "other")))
        await assertError(.invalidCursor) { _ = try await fixture.service.load(target: other, cursor: first.cursor) }
    }

    func testKeyOnlyContinuationMarkerIsSupportedWithoutInventedVersion() async throws {
        let target = versionsTarget()
        let fixture = S3VersionsFixture(pages: [.init(isTruncated: true, name: target.context.bucket,
            nextKeyMarker: target.key + ".bak", prefix: target.key)])
        let first = try await fixture.service.load(target: target, cursor: nil)
        XCTAssertNil(first.cursor?.marker.versionID)
        XCTAssertEqual(first.cursor?.marker.key, target.key + ".bak")
    }

    func testRepeatedMarkersAndMissingKeyMarkerRejectTruncatedResponse() async throws {
        let target = versionsTarget()
        let page = S3.ListObjectVersionsOutput(isTruncated: true, name: target.context.bucket,
            nextKeyMarker: target.key, nextVersionIdMarker: "v1", prefix: target.key)
        let repeated = S3.ListObjectVersionsOutput(isTruncated: true, keyMarker: target.key, name: target.context.bucket,
            nextKeyMarker: target.key, nextVersionIdMarker: "v1", prefix: target.key, versionIdMarker: "v1")
        let fixture = S3VersionsFixture(pages: [page, repeated])
        let first = try await fixture.service.load(target: target, cursor: nil)
        await assertError(.incompletePagination) { _ = try await fixture.service.load(target: target, cursor: first.cursor) }
        let invalid = S3VersionsFixture(pages: [.init(isTruncated: true, name: target.context.bucket,
            nextVersionIdMarker: "v1", prefix: target.key)])
        await assertError(.incompletePagination) { _ = try await invalid.service.load(target: target, cursor: nil) }
    }

    func testForeignBucketPrefixMalformedVersionsAndDuplicateVersionIDsReject() async {
        let target = versionsTarget()
        let pages: [S3.ListObjectVersionsOutput] = [
            .init(isTruncated: false, name: "other-bucket", prefix: target.key),
            .init(isTruncated: false, name: target.context.bucket, prefix: "other"),
            .init(isTruncated: false, name: target.context.bucket, prefix: target.key, versions: [.init(key: "other", versionId: "v")]),
            .init(isTruncated: false, name: target.context.bucket, prefix: target.key, versions: [.init(key: target.key)]),
            .init(isTruncated: false, name: target.context.bucket, prefix: target.key, versions: [.init(key: target.key, size: -1, versionId: "v")]),
            .init(deleteMarkers: [.init(key: target.key, versionId: "v")], isTruncated: false, name: target.context.bucket,
                  prefix: target.key, versions: [.init(key: target.key, versionId: "v")])
        ]
        for page in pages {
            let fixture = S3VersionsFixture(pages: [page])
            await assertError(.invalidResponse) { _ = try await fixture.service.load(target: target, cursor: nil) }
        }
    }

    func testSecondPageFailureIsSafeAndDoesNotReturnFakeCompletePage() async throws {
        let target = versionsTarget()
        let fixture = S3VersionsFixture(pages: [.init(isTruncated: true, name: target.context.bucket,
            nextKeyMarker: target.key, nextVersionIdMarker: "v", prefix: target.key)], failAt: 1)
        let first = try await fixture.service.load(target: target, cursor: nil)
        await assertError(.permission) { _ = try await fixture.service.load(target: target, cursor: first.cursor) }
        XCTAssertFalse(S3VersionsError.permission.localizedDescription.contains("private-test-content"))
    }

    func testCancellationBeforeLoadPreventsRequest() async {
        let fixture = S3VersionsFixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.service.load(target: versionsTarget(), cursor: nil)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await fixture.inputs.count
        XCTAssertEqual(count, 0)
    }

    private func assertError(_ expected: S3VersionsError, operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected rejection", file: file, line: line) }
        catch { XCTAssertEqual(error as? S3VersionsError, expected, file: file, line: line) }
    }
}
