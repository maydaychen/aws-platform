import CryptoKit
import Darwin
import SotoCore
import SotoS3
import XCTest
@testable import AWSPlatform

final class S3TransferSecurityTests: XCTestCase {
    func testCancelledPreparationLeavesNoLocalSnapshot() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let gate = TestGate()
        let request = Task {
            await gate.wait()
            return try await S3LocalFile.prepare(url: file.url, temporaryRoot: directory)
        }
        await gate.waitForEntry()
        request.cancel()
        await gate.open()
        do { _ = try await request.value; XCTFail("Cancelled preparation must not show a confirmation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["file.txt"])
    }

    func testRestoringSizeAndModificationTimeCannotHideSourceMutation() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let reader = try S3UploadReader(file: file, progress: { _ in })
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.write(contentsOf: Data("tamper".utf8))
        try handle.close()
        let times = [timespec(tv_sec: Int(file.fingerprint.seconds), tv_nsec: Int(file.fingerprint.nanoseconds)),
                     timespec(tv_sec: Int(file.fingerprint.seconds), tv_nsec: Int(file.fingerprint.nanoseconds))]
        XCTAssertEqual(utimensat(AT_FDCWD, file.url.path, times, 0), 0)
        let changed = try XCTUnwrap(S3FileFingerprint.at(file.url))
        XCTAssertEqual(changed.size, file.fingerprint.size)
        XCTAssertEqual(changed.seconds, file.fingerprint.seconds)
        XCTAssertEqual(changed.nanoseconds, file.fingerprint.nanoseconds)
        do { try await reader.validate(); XCTFail("ctime must expose the hidden mutation") }
        catch { XCTAssertEqual(error as? S3TransferError, .fileChanged) }
        await reader.close()
    }

    func testPreparedUploadUsesConfirmedSnapshotAndCleansItWhenReleased() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("confirmed".utf8)
        let file = try S3TransferFixtures.file(in: directory, data: original)
        var prepared: S3LocalFile? = try await S3LocalFile.prepare(url: file.url, temporaryRoot: directory)
        let snapshot = try XCTUnwrap(prepared).contentURL
        XCTAssertNotEqual(snapshot, file.url)
        XCTAssertEqual(prepared?.checksumSHA256, Data(SHA256.hash(data: original)).base64EncodedString())
        try Data("different".utf8).write(to: file.url)
        XCTAssertEqual(try Data(contentsOf: snapshot), original)
        let service = AWSS3TransferService(regionLoader: { _ in "ap-southeast-1" }, put: { _, request in
            XCTAssertEqual(request.checksumSHA256, Data(SHA256.hash(data: original)).base64EncodedString())
            var sent = Data()
            for try await chunk in try XCTUnwrap(request.body) { sent.append(contentsOf: chunk.readableBytesView) }
            XCTAssertEqual(sent, original)
        }, head: { _, _ in XCTFail("No collision"); return .init() }, get: { _, _ in XCTFail("No GET"); return .init(body: .init()) })
        try await service.upload(.init(context: S3TransferFixtures.context(), file: try XCTUnwrap(prepared), key: "confirmed"), progress: { _ in })
        prepared = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.deletingLastPathComponent().path))
    }

    func testDownloadByteBudgetAndDiskReserveFailBeforeWritingExcessBytes() throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let destination = try S3DownloadDestination(url: file.url)
        XCTAssertThrowsError(try S3DownloadWriter(destination: destination, expectedLength: 1, capacity: { _ in 0 })) {
            XCTAssertEqual($0 as? S3TransferError, .insufficientSpace)
        }
        let bounded = try S3DownloadWriter(destination: destination, expectedLength: 2)
        XCTAssertThrowsError(try bounded.write(Data("too large".utf8))) {
            XCTAssertEqual($0 as? S3TransferError, .incompleteDownload)
        }
        XCTAssertEqual(bounded.bytes, 0)
        bounded.cleanup()
        let outOfSpace = try S3DownloadWriter(destination: destination, capacity: { _ in S3DownloadWriter.minimumFreeSpace })
        XCTAssertThrowsError(try outOfSpace.write(Data([1]))) {
            XCTAssertEqual($0 as? S3TransferError, .insufficientSpace)
        }
        outOfSpace.cleanup()
        XCTAssertEqual(try Data(contentsOf: file.url), Data("sample".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["file.txt"])
    }

    func testAncestorReplacementCannotRedirectCommitOrCleanup() throws {
        let root = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let chosen = root.appendingPathComponent("chosen", isDirectory: true)
        let moved = root.appendingPathComponent("moved", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let file = try S3TransferFixtures.file(in: chosen)
        let writer = try S3DownloadWriter(destination: .init(url: file.url), expectedLength: 2)
        let temporaryName = writer.temporaryURL.lastPathComponent
        try writer.write(Data("ok".utf8))
        try FileManager.default.moveItem(at: chosen, to: moved)
        try FileManager.default.createSymbolicLink(at: chosen, withDestinationURL: other)
        let marker = other.appendingPathComponent(temporaryName)
        try Data("keep".utf8).write(to: marker)
        XCTAssertThrowsError(try writer.commit(expectedLength: 2)) {
            XCTAssertEqual($0 as? S3TransferError, .destinationChanged)
        }
        writer.cleanup()
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("file.txt")), Data("sample".utf8))
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("file.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent(temporaryName).path))
    }

    func testChangedResponseAndOversizedBodyNeverReplaceDestination() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let object = S3ObjectModel(key: "file", size: 2, lastModified: nil, storageClass: nil, isPrefix: false, eTag: "etag")
        for response in [S3.GetObjectOutput(body: .init(string: "ok"), contentLength: 2, eTag: "different"),
                         .init(body: .init(string: "ok"), contentLength: 3, eTag: "etag"),
                         .init(body: .init(string: "oversized"), contentLength: 2, eTag: "etag")] {
            let service = AWSS3TransferService(regionLoader: { _ in "ap-southeast-1" }, put: { _, _ in XCTFail("No PUT") },
                head: { _, _ in XCTFail("No HEAD"); return .init() }, get: { _, request in
                    XCTAssertEqual(request.ifMatch, "etag")
                    XCTAssertEqual(request.expectedBucketOwner, "111122223333")
                    return response
                })
            do {
                try await service.download(context: S3TransferFixtures.context(), object: object,
                    destination: .init(url: file.url), progress: { _ in })
                XCTFail("Unconfirmed or oversized responses must fail")
            } catch { XCTAssertTrue([S3TransferError.objectChanged, .incompleteDownload].contains(error as? S3TransferError ?? .failed)) }
            XCTAssertEqual(try Data(contentsOf: file.url), Data("sample".utf8))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["file.txt"])
    }
}
