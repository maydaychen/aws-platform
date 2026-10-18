import Foundation
import SotoS3
import XCTest
@testable import AWSPlatform

final class S3VersionsByteIdentityTests: XCTestCase {
    private let composed = "reports/\u{e9}%2F.csv"
    private let decomposed = "reports/e\u{301}%2F.csv"

    func testTargetsMarkersAndVersionIDsUseLiteralUTF8Identity() {
        XCTAssertEqual(composed, decomposed)
        let first = versionsTarget(key: composed)
        let second = versionsTarget(key: decomposed)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 2)
        XCTAssertEqual(Set([S3VersionsMarker(key: composed, versionID: "v"),
                            S3VersionsMarker(key: decomposed, versionID: "v")]).count, 2)
        XCTAssertEqual(Set([S3VersionsMarker(key: composed, versionID: "\u{e9}"),
                            S3VersionsMarker(key: composed, versionID: "e\u{301}")]).count, 2)
        let versions = [byteVersion("\u{e9}"), byteVersion("e\u{301}")]
        XCTAssertEqual(Set(versions.map(\.id)).count, 2)
        XCTAssertEqual(Set(versions).count, 2)
    }

    func testHistoryKeyLimitCountsUTF8BytesWithoutTransferFilenameRestrictions() {
        let maximum = "reports/" + String(repeating: "\u{e9}", count: 508)
        XCTAssertEqual(maximum.utf8.count, 1_024)
        XCTAssertTrue(versionsTarget(key: maximum).isValid)
        XCTAssertFalse(versionsTarget(key: maximum + "x").isValid)
        XCTAssertFalse(S3VersionsTarget.validKey(""))
        XCTAssertTrue(versionsTarget(key: "reports/\0\u{1}\n").isValid)
    }

    func testInitialNilAndEmptyMarkerEchoesAreAcceptedButForeignEchoesReject() async throws {
        let target = versionsTarget(key: "reports/object")
        for keyMarker: String? in [nil, ""] {
            for versionMarker: String? in [nil, ""] {
                let fixture = S3VersionsFixture(pages: [.init(encodingType: .url, isTruncated: false, keyMarker: keyMarker,
                    name: target.context.bucket, prefix: "reports%2Fobject", versionIdMarker: versionMarker,
                    versions: [.init(key: "reports%2Fobject", versionId: "v")])])
                let page = try await fixture.service.load(target: target, cursor: nil)
                XCTAssertEqual(page.versions.map(\.versionID), ["v"])
                XCTAssertNil(page.cursor)
            }
        }
        for page in [S3.ListObjectVersionsOutput(isTruncated: false, keyMarker: "foreign", name: target.context.bucket, prefix: target.key),
                     .init(isTruncated: false, name: target.context.bucket, prefix: target.key, versionIdMarker: "foreign")] {
            let fixture = S3VersionsFixture(pages: [page])
            await assertError(.invalidResponse) { _ = try await fixture.service.load(target: target, cursor: nil) }
        }
    }

    func testContinuedPageRequiresExactRequestedEchoAndAllowsEmptyUnrequestedVersionEcho() async throws {
        let target = versionsTarget(key: composed)
        let marker = S3VersionsMarker(key: composed, versionID: "v")
        let cursor = S3VersionsCursor(target: target, marker: marker, seenMarkers: [marker], pagesRead: 1)
        for keyEcho: String? in [nil, "", decomposed] {
            let fixture = S3VersionsFixture(pages: [.init(isTruncated: false, keyMarker: keyEcho,
                name: target.context.bucket, prefix: composed, versionIdMarker: "v")])
            await assertError(.invalidResponse) { _ = try await fixture.service.load(target: target, cursor: cursor) }
        }
        for versionEcho: String? in [nil, ""] {
            let fixture = S3VersionsFixture(pages: [.init(isTruncated: false, keyMarker: composed,
                name: target.context.bucket, prefix: composed, versionIdMarker: versionEcho)])
            await assertError(.invalidResponse) { _ = try await fixture.service.load(target: target, cursor: cursor) }
        }
        let keyOnly = S3VersionsMarker(key: composed, versionID: nil)
        let keyOnlyCursor = S3VersionsCursor(target: target, marker: keyOnly, seenMarkers: [keyOnly], pagesRead: 1)
        let fixture = S3VersionsFixture(pages: [.init(isTruncated: false, keyMarker: composed,
            name: target.context.bucket, prefix: composed, versionIdMarker: "")])
        let last = try await fixture.service.load(target: target, cursor: keyOnlyCursor)
        XCTAssertNil(last.cursor)
    }

    func testPrefixRelationshipRejectsCanonicallyEquivalentForeignPrefix() async {
        let context = S3TransferContext(scope: logsVersionsScope(), bucket: "example-bucket",
            prefix: "reports/\u{e9}", knownRegion: "eu-west-1")
        let foreign = versionsTarget(context: context, key: decomposed)
        XCTAssertFalse(foreign.isValid)
        let fixture = S3VersionsFixture()
        await assertError(.invalidScope) { _ = try await fixture.service.resolve(context: context, key: self.decomposed) }
        let requests = await fixture.inputs.count
        XCTAssertEqual(requests, 0)
    }

    func testCanonicalNeighbourInResponsePrefixKeyAndNextMarkerIsRejected() async {
        let target = versionsTarget(key: composed)
        let pages: [(S3.ListObjectVersionsOutput, S3VersionsError)] = [
            (.init(isTruncated: false, name: target.context.bucket, prefix: decomposed), .invalidResponse),
            (.init(isTruncated: false, name: target.context.bucket, prefix: composed,
                   versions: [.init(key: decomposed, versionId: "foreign")]), .invalidResponse),
            (.init(deleteMarkers: [.init(key: decomposed, versionId: "foreign")], isTruncated: false,
                   name: target.context.bucket, prefix: composed), .invalidResponse),
            (.init(isTruncated: true, name: target.context.bucket, nextKeyMarker: decomposed,
                   nextVersionIdMarker: "foreign", prefix: composed), .incompletePagination)
        ]
        for (page, error) in pages {
            let fixture = S3VersionsFixture(pages: [page])
            await assertError(error) { _ = try await fixture.service.load(target: target, cursor: nil) }
        }
    }

    func testCursorTargetSeenMarkerAndResponseEchoesAreByteExact() async throws {
        let target = versionsTarget(key: composed)
        let first = S3.ListObjectVersionsOutput(isTruncated: true, name: target.context.bucket,
            nextKeyMarker: composed, nextVersionIdMarker: "\u{e9}", prefix: composed)
        let fixture = S3VersionsFixture(pages: [first])
        let page = try await fixture.service.load(target: target, cursor: nil)
        let cursor = try XCTUnwrap(page.cursor)
        await assertError(.invalidCursor) {
            _ = try await fixture.service.load(target: versionsTarget(key: self.decomposed), cursor: cursor)
        }
        let mismatchedSeen = S3VersionsCursor(target: target, marker: cursor.marker,
            seenMarkers: [.init(key: composed, versionID: "e\u{301}")], pagesRead: 1)
        await assertError(.invalidCursor) { _ = try await fixture.service.load(target: target, cursor: mismatchedSeen) }
        let requestCount = await fixture.inputs.count
        XCTAssertEqual(requestCount, 1)
        for second in [S3.ListObjectVersionsOutput(isTruncated: false, keyMarker: decomposed,
                            name: target.context.bucket, prefix: composed, versionIdMarker: "\u{e9}"),
                       .init(isTruncated: false, keyMarker: composed, name: target.context.bucket,
                             prefix: composed, versionIdMarker: "e\u{301}")] {
            let wrongEcho = S3VersionsFixture(pages: [second])
            await assertError(.invalidResponse) { _ = try await wrongEcho.service.load(target: target, cursor: cursor) }
        }
    }

    func testBothUnicodeObjectsAndLiteralPercentPaginateWithoutNormalizingOrDecoding() async throws {
        for key in [composed, decomposed] {
            let target = versionsTarget(key: key)
            let fixture = S3VersionsFixture(pages: [
                .init(isTruncated: true, name: target.context.bucket, nextKeyMarker: key, nextVersionIdMarker: "v1",
                      prefix: key, versions: [.init(key: key, versionId: "v1")]),
                .init(isTruncated: false, keyMarker: key, name: target.context.bucket, prefix: key,
                      versionIdMarker: "v1", versions: [.init(key: key, versionId: "v2")])
            ])
            let first = try await fixture.service.load(target: target, cursor: nil)
            let last = try await fixture.service.load(target: target, cursor: try XCTUnwrap(first.cursor))
            XCTAssertEqual(first.versions.map(\.versionID) + last.versions.map(\.versionID), ["v1", "v2"])
            XCTAssertNil(last.cursor)
            let requests = await fixture.inputs
            XCTAssertEqual(requests.map { $0.prefix.map { Data($0.utf8) } }, [Data(key.utf8), Data(key.utf8)])
            XCTAssertEqual(requests[1].keyMarker.map { Data($0.utf8) }, Data(key.utf8))
            XCTAssertEqual(last.target.key.utf8.count, key.utf8.count)
        }
    }

    func testByteDistinctVersionMarkersDoNotProduceFalsePaginationCycle() async throws {
        let target = versionsTarget(key: composed)
        let fixture = S3VersionsFixture(pages: [
            .init(isTruncated: true, name: target.context.bucket, nextKeyMarker: composed,
                  nextVersionIdMarker: "\u{e9}", prefix: composed),
            .init(isTruncated: true, keyMarker: composed, name: target.context.bucket, nextKeyMarker: composed,
                  nextVersionIdMarker: "e\u{301}", prefix: composed, versionIdMarker: "\u{e9}"),
            .init(isTruncated: false, keyMarker: composed, name: target.context.bucket, prefix: composed,
                  versionIdMarker: "e\u{301}")
        ])
        let first = try await fixture.service.load(target: target, cursor: nil)
        let second = try await fixture.service.load(target: target, cursor: first.cursor)
        XCTAssertEqual(second.cursor?.seenMarkers.count, 2)
        let last = try await fixture.service.load(target: target, cursor: second.cursor)
        XCTAssertNil(last.cursor)
    }

    func testURLEncodedXMLHostileKeyRoundTripsOnceWhileVersionMarkersStayLiteral() async throws {
        let key = "reports/\u{0}\u{1}\u{e9}%2F+new\n"
        let encodedKey = "reports%2F%00%01%C3%A9%252F%2Bnew%0A"
        let versionID = "v%252F+id"
        let target = versionsTarget(key: key)
        XCTAssertTrue(target.isValid)
        let fixture = S3VersionsFixture(pages: [
            .init(encodingType: .url, isTruncated: true, name: target.context.bucket, nextKeyMarker: encodedKey,
                  nextVersionIdMarker: versionID, prefix: encodedKey, versions: [.init(key: encodedKey, versionId: versionID)]),
            .init(deleteMarkers: [.init(key: encodedKey, versionId: "deleted%2F+")], encodingType: .url,
                  isTruncated: false, keyMarker: encodedKey, name: target.context.bucket, prefix: encodedKey, versionIdMarker: versionID)
        ])
        let resolved = try await fixture.service.resolve(context: target.context, key: key)
        XCTAssertEqual(resolved, target)
        let first = try await fixture.service.load(target: resolved, cursor: nil)
        let cursor = try XCTUnwrap(first.cursor)
        XCTAssertEqual(Data(cursor.marker.key.utf8), Data(key.utf8))
        XCTAssertEqual(cursor.marker.versionID, versionID)
        XCTAssertEqual(first.versions.first?.versionID, versionID)
        let last = try await fixture.service.load(target: target, cursor: cursor)
        XCTAssertEqual(last.versions.first?.versionID, "deleted%2F+")
        XCTAssertEqual(last.versions.first?.kind, .deleteMarker)
        XCTAssertNil(last.cursor)
        let requests = await fixture.inputs
        XCTAssertTrue(requests.allSatisfy { $0.encodingType == .url && $0.expectedBucketOwner == target.context.scope.accountID })
        XCTAssertEqual(requests.map { $0.prefix.map { Data($0.utf8) } }, [Data(key.utf8), Data(key.utf8)])
        XCTAssertEqual(requests[1].keyMarker.map { Data($0.utf8) }, Data(key.utf8))
        XCTAssertEqual(requests[1].versionIdMarker, versionID)
    }

    func testEncodedResponseDoesNotTranslateLiteralPlusOrDecodePercentTwice() async throws {
        let key = "reports/a+b%2F"
        let encoded = "reports%2Fa+b%252F"
        let target = versionsTarget(key: key)
        let fixture = S3VersionsFixture(pages: [.init(encodingType: .url, isTruncated: false, name: target.context.bucket,
            prefix: encoded, versions: [.init(key: encoded, versionId: "v%2F+")])])
        let page = try await fixture.service.load(target: target, cursor: nil)
        XCTAssertEqual(page.versions.map(\.versionID), ["v%2F+"])
        XCTAssertEqual(Data(page.target.key.utf8), Data(key.utf8))
    }

    func testMalformedPercentAndInvalidUTF8AreRejectedInEveryConsumedEncodedKeyField() async {
        let target = versionsTarget(key: "reports/object")
        for malformed in ["%", "%GG", "%FF", "%C3%28", "%E0%80%AF"] {
            let fixture = S3VersionsFixture(pages: [.init(encodingType: .url, isTruncated: false,
                name: target.context.bucket, prefix: malformed)])
            await assertError(.invalidResponse) { _ = try await fixture.service.load(target: target, cursor: nil) }
        }
        let encoded = "reports%2Fobject"
        let pages: [S3.ListObjectVersionsOutput] = [
            .init(encodingType: .url, isTruncated: false, name: target.context.bucket, prefix: encoded,
                  versions: [.init(key: "%GG", versionId: "v")]),
            .init(deleteMarkers: [.init(key: "%GG", versionId: "v")], encodingType: .url, isTruncated: false,
                  name: target.context.bucket, prefix: encoded),
            .init(encodingType: .url, isTruncated: true, name: target.context.bucket, nextKeyMarker: "%GG", prefix: encoded),
            .init(encodingType: .url, isTruncated: false, keyMarker: "%GG", name: target.context.bucket, prefix: encoded)
        ]
        for page in pages {
            let fixture = S3VersionsFixture(pages: [page])
            await assertError(.invalidResponse) { _ = try await fixture.service.load(target: target, cursor: nil) }
        }
    }

    private func assertError(_ expected: S3VersionsError, operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected rejection", file: file, line: line) }
        catch { XCTAssertEqual(error as? S3VersionsError, expected, file: file, line: line) }
    }
}

@MainActor
final class S3VersionsByteIdentityViewModelTests: XCTestCase {
    func testCanonicalObjectSwitchReadsBothCompletePageSequencesWithoutReusingCursor() async {
        let objects = [("reports/\u{e9}%2F", "first"), ("reports/e\u{301}%2F", "second")]
        let pages: [S3.ListObjectVersionsOutput] = objects.flatMap { key, id in
            [.init(isTruncated: true, name: "example-bucket", nextKeyMarker: key, nextVersionIdMarker: id + "-1", prefix: key,
                   versions: [.init(key: key, versionId: id + "-1")]),
             .init(isTruncated: false, keyMarker: key, name: "example-bucket", prefix: key, versionIdMarker: id + "-1",
                   versions: [.init(key: key, versionId: id + "-2")])]
        }
        let fixture = S3VersionsFixture(pages: pages)
        let service = fixture.service
        let vm = S3VersionsViewModel(resolver: { try await service.resolve(context: $0, key: $1) },
            loader: { try await service.load(target: $0, cursor: $1) })
        for (key, id) in objects {
            vm.configure(context: versionsContext(), key: key)
            XCTAssertTrue(vm.versions.isEmpty)
            XCTAssertFalse(vm.hasMore)
            vm.load(); await vm.waitForLoading()
            XCTAssertEqual(vm.versions.map(\.versionID), [id + "-1"])
            XCTAssertTrue(vm.hasMore)
            vm.loadMore(); await vm.waitForLoading()
            XCTAssertEqual(vm.versions.map(\.versionID), [id + "-1", id + "-2"])
            XCTAssertFalse(vm.hasMore)
            XCTAssertNil(vm.error)
        }
        let inputs = await fixture.inputs
        XCTAssertEqual(inputs.map { $0.prefix.map { Data($0.utf8) } }, objects.flatMap { [Data($0.0.utf8), Data($0.0.utf8)] })
        XCTAssertEqual(inputs.map(\.versionIdMarker), [nil, "first-1", nil, "second-1"])
    }

    func testCanonicalObjectSwitchClearsVersionsCursorAndLoadedState() async {
        let vm = S3VersionsViewModel(resolver: { versionsTarget(context: $0, key: $1) }, loader: { target, _ in
            let marker = S3VersionsMarker(key: target.key, versionID: "v1")
            return .init(target: target, versions: [byteVersion("v1")],
                cursor: .init(target: target, marker: marker, seenMarkers: [marker], pagesRead: 1))
        })
        vm.configure(context: versionsContext(), key: "reports/\u{e9}")
        vm.load(); await vm.waitForLoading()
        XCTAssertTrue(vm.hasLoaded)
        XCTAssertTrue(vm.hasMore)
        vm.configure(context: versionsContext(), key: "reports/e\u{301}")
        XCTAssertTrue(vm.versions.isEmpty)
        XCTAssertFalse(vm.hasMore)
        XCTAssertFalse(vm.hasLoaded)
        XCTAssertEqual(vm.key.map { Data($0.utf8) }, Data("reports/e\u{301}".utf8))
        vm.load(); await vm.waitForLoading()
        XCTAssertTrue(vm.hasLoaded)
        XCTAssertNil(vm.error)
    }

    func testByteDistinctContextPrefixStillInvalidatesSameObject() async {
        let scope = logsVersionsScope()
        let composed = S3TransferContext(scope: scope, bucket: "example-bucket", prefix: "reports/\u{e9}", knownRegion: "eu-west-1")
        let decomposed = S3TransferContext(scope: scope, bucket: "example-bucket", prefix: "reports/e\u{301}", knownRegion: "eu-west-1")
        let vm = S3VersionsViewModel(resolver: { versionsTarget(context: $0, key: $1) },
            loader: { target, _ in .init(target: target, versions: [byteVersion("v1")], cursor: nil) })
        vm.configure(context: composed, key: "reports/\u{e9}.csv")
        vm.load(); await vm.waitForLoading()
        XCTAssertTrue(vm.hasLoaded)
        vm.configure(context: decomposed, key: "reports/\u{e9}.csv")
        XCTAssertTrue(vm.versions.isEmpty)
        XCTAssertFalse(vm.hasLoaded)
    }

    func testLateSuccessAndFailureAreDiscardedAfterCanonicalObjectSwitch() async {
        for failure in [false, true] {
            let gate = LogsVersionsGate()
            let vm = S3VersionsViewModel(resolver: { versionsTarget(context: $0, key: $1) }, loader: { target, _ in
                await gate.enter()
                if failure { throw LogsVersionsFixtureError("AccessDenied") }
                return .init(target: target, versions: [byteVersion("old")], cursor: nil)
            })
            vm.configure(context: versionsContext(), key: "reports/\u{e9}")
            vm.load(); await gate.waitForEntry()
            let pending = Task { await vm.waitForLoading() }
            await Task.yield()
            vm.configure(context: versionsContext(), key: "reports/e\u{301}")
            await gate.open(); await pending.value
            XCTAssertTrue(vm.versions.isEmpty)
            XCTAssertNil(vm.error)
            XCTAssertFalse(vm.isLoading)
            XCTAssertFalse(vm.hasLoaded)
        }
    }

    func testCanonicalForeignResolvedTargetsPagesAndCursorsNeverDisplay() async {
        let target = versionsTarget(key: "reports/\u{e9}")
        let foreign = versionsTarget(key: "reports/e\u{301}")
        for variant in 0..<3 {
            let vm = S3VersionsViewModel(resolver: { _, _ in variant == 0 ? foreign : target }, loader: { _, _ in
                let marker = S3VersionsMarker(key: foreign.key, versionID: "v")
                return .init(target: variant == 1 ? foreign : target, versions: [byteVersion("foreign")],
                    cursor: variant == 2 ? .init(target: foreign, marker: marker, seenMarkers: [marker], pagesRead: 1) : nil)
            })
            vm.configure(context: target.context, key: target.key)
            vm.load(); await vm.waitForLoading()
            XCTAssertTrue(vm.versions.isEmpty)
            XCTAssertNotNil(vm.error)
        }
    }

    func testByteDistinctVersionRowsSurviveViewModelMerge() async {
        let vm = S3VersionsViewModel(resolver: { versionsTarget(context: $0, key: $1) }, loader: { target, _ in
            .init(target: target, versions: [byteVersion("\u{e9}"), byteVersion("e\u{301}")], cursor: nil)
        })
        vm.configure(context: versionsContext(), key: "reports/object")
        vm.load(); await vm.waitForLoading()
        XCTAssertEqual(vm.versions.count, 2)
        XCTAssertEqual(Set(vm.versions.map(\.id)).count, 2)
        XCTAssertNil(vm.error)
    }
}

private func byteVersion(_ id: String) -> S3ObjectVersion {
    .init(versionID: id, kind: .version, isLatest: nil, lastModified: nil, size: nil, eTag: nil, storageClass: nil)
}
