import Foundation
import SotoCore
import SotoS3
import XCTest
@testable import AWSPlatform

final class AWSS3TransferServiceTests: XCTestCase {
    private func service(
        region: @escaping AWSS3TransferService.RegionLoader = { _ in "ap-southeast-1" },
        put: @escaping AWSS3TransferService.Put = { _, _ in },
        head: @escaping AWSS3TransferService.Head = { _, _ in .init(eTag: "\"original\"") },
        get: @escaping AWSS3TransferService.Get = { _, _ in .init(body: .init(), contentLength: 0) }
    ) -> AWSS3TransferService {
        .init(regionLoader: region, put: put, head: head, get: get)
    }

    func testNewUploadIsConditionalScopedAndStreamsTheWholeFile() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data(repeating: 65, count: 600_000)
        let file = try S3TransferFixtures.file(in: directory, data: data)
        let context = S3TransferFixtures.context()
        let client = service(put: { target, request in
            XCTAssertEqual(target.region, "ap-southeast-1")
            XCTAssertEqual(target.context.scope, context.scope)
            XCTAssertEqual(request.expectedBucketOwner, "111122223333")
            XCTAssertEqual(request.bucket, "example-bucket")
            XCTAssertEqual(request.key, "folder/file.txt")
            XCTAssertEqual(request.ifNoneMatch, "*")
            XCTAssertNil(request.ifMatch)
            XCTAssertNil(request.acl)
            XCTAssertNil(request.tagging)
            XCTAssertEqual(request.contentLength, Int64(data.count))
            var received = Data()
            for try await chunk in try XCTUnwrap(request.body) { received.append(contentsOf: chunk.readableBytesView) }
            XCTAssertEqual(received, data)
        })
        try await client.upload(.init(context: context, file: file, key: "folder/file.txt"), progress: { _ in })
    }

    func testExistingObjectRequiresETagConfirmationAndOverwriteUsesIfMatch() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let context = S3TransferFixtures.context(region: nil)
        var intent = S3UploadIntent(context: context, file: file, key: "folder/file.txt")
        let first = service(put: { _, _ in throw AWSResponseError(errorCode: "PreconditionFailed") }, head: { target, request in
            XCTAssertEqual(target.region, "ap-southeast-1")
            XCTAssertEqual(request.expectedBucketOwner, context.scope.accountID)
            return .init(eTag: "\"original\"")
        })
        do {
            try await first.upload(intent, progress: { _ in })
            XCTFail("A collision must not cause automatic overwrite")
        } catch {
            XCTAssertEqual(error as? S3TransferError, .objectExists(etag: "\"original\"", region: "ap-southeast-1"))
        }
        intent.overwriteETag = "\"original\""
        intent.resolvedRegion = "ap-southeast-1"
        let confirmed = service(region: { _ in XCTFail("Reuse captured Bucket region"); return "us-east-1" }, put: { _, request in
            XCTAssertEqual(request.ifMatch, "\"original\"")
            XCTAssertNil(request.ifNoneMatch)
        })
        try await confirmed.upload(intent, progress: { _ in })
    }

    func testChangedObjectAndMissingHeadPermissionNeverFallBackToUnconditionalPut() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let context = S3TransferFixtures.context()
        for code in ["PreconditionFailed", "ConditionalRequestConflict"] {
            var intent = S3UploadIntent(context: context, file: file, key: "file")
            intent.overwriteETag = "etag"
            do {
                try await service(put: { _, _ in throw AWSResponseError(errorCode: code) }).upload(intent, progress: { _ in })
                XCTFail("Changed objects require fresh review")
            } catch { XCTAssertEqual(error as? S3TransferError, .objectChanged) }
        }
        do {
            try await service(put: { _, _ in throw AWSResponseError(errorCode: "PreconditionFailed") }, head: { _, _ in
                throw AWSResponseError(errorCode: "AccessDenied")
            }).upload(.init(context: context, file: file, key: "file"), progress: { _ in })
            XCTFail("No safe overwrite without an ETag")
        } catch { XCTAssertEqual(error as? S3TransferError, .accessDenied) }
    }

    func testRegionLookupFailureDoesNotFallBackOrWrite() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        for region in [nil, "invalid", "cn-north-1"] as [String?] {
            let context = S3TransferFixtures.context(region: region)
            let client = service(region: { _ in throw AWSResponseError(errorCode: "AccessDenied") }, put: { _, _ in
                XCTFail("Never PUT with an unknown or wrong-partition Bucket region")
            })
            do {
                try await client.upload(.init(context: context, file: file, key: "file"), progress: { _ in })
                XCTFail("A real Bucket region is required")
            } catch { XCTAssertEqual(error as? S3TransferError, .regionUnavailable) }
        }
    }

    func testDownloadScopesGetAndPreservesOriginalOnTruncationOrFailure() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let context = S3TransferFixtures.context()
        let client = service(get: { target, request in
            XCTAssertEqual(target.region, "ap-southeast-1")
            XCTAssertEqual(request.expectedBucketOwner, context.scope.accountID)
            XCTAssertEqual(request.key, "../../unsafe/path.txt")
            return .init(body: .init(string: "partial"), contentLength: 100)
        })
        do {
            try await client.download(context: context, key: "../../unsafe/path.txt", destination: .init(url: file.url), progress: { _ in })
            XCTFail("Truncated transfer must fail")
        } catch { XCTAssertEqual(error as? S3TransferError, .incompleteDownload) }
        XCTAssertEqual(try Data(contentsOf: file.url), Data("sample".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["file.txt"])
    }

    func testEmptyDownloadSucceedsAndCancellationPreservesExistingFile() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let context = S3TransferFixtures.context()
        try await service().download(context: context, key: "empty", destination: .init(url: file.url), progress: { _ in })
        XCTAssertEqual(try Data(contentsOf: file.url).count, 0)
        let gate = TestGate()
        let delayed = service(get: { _, _ in
            await gate.wait()
            return .init(body: .init(string: "late"), contentLength: 4)
        })
        let task = Task {
            try await delayed.download(context: context, key: "file", destination: .init(url: file.url), progress: { _ in })
        }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        do { try await task.value; XCTFail("Cancelled transfer must not commit") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file.url).count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["file.txt"])
    }

    func testErrorMappingAndChineseMessagesDoNotExposeProviderDetails() {
        for (code, expected) in [("AccessDenied", S3TransferError.accessDenied), ("InvalidObjectState", .archivedObject),
                                 ("NoSuchKey", .notFound), ("PreconditionFailed", .objectChanged), ("Unexpected", .failed)] {
            XCTAssertEqual(AWSS3TransferService.map(AWSResponseError(errorCode: code)) as? S3TransferError, expected)
            let message = expected.errorDescription!
            XCTAssertNotEqual(L10n.text(message, locale: Locale(identifier: "zh-Hans")), message)
        }
    }

    func testMidStreamFailureAndCancellationCleanPartialDownloads() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let context = S3TransferFixtures.context()
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("partial".utf8))
            continuation.finish(throwing: S3TransferError.failed)
        }
        do {
            try await service(get: { _, _ in
                .init(body: .init(asyncSequence: stream, length: 10), contentLength: 10)
            }).download(context: context, key: "file", destination: .init(url: file.url), progress: { _ in })
            XCTFail("A failed stream must not replace the local file")
        } catch { XCTAssertEqual(error as? S3TransferError, .failed) }
        XCTAssertEqual(try Data(contentsOf: file.url), Data("sample".utf8))
        let gate = TestGate()
        let partial = service(get: { _, _ in .init(body: .init(string: "partial"), contentLength: 7) })
        let download = Task {
            try await partial
                .download(context: context, key: "file", destination: .init(url: file.url), progress: { _ in await gate.wait() })
        }
        await gate.waitForEntry()
        download.cancel()
        await gate.open()
        do { try await download.value; XCTFail("Cancellation must preserve the original") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file.url), Data("sample".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["file.txt"])
    }
}
