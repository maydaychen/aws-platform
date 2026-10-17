import Darwin
import Foundation
import XCTest
@testable import AWSPlatform

final class S3DownloadRecoveryTests: XCTestCase {
    func testEditAtActualExchangeBoundaryIsRetainedAsRecoveryCopy() throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("document.txt")
        try Data("original".utf8).write(to: url)
        let writer = try S3DownloadWriter(destination: .init(url: url), rename: { fromFD, from, toFD, to, flags in
            XCTAssertEqual(flags, UInt32(RENAME_SWAP))
            // Simulate an editor's atomic save after commit's final fingerprint
            // check, at the actual filesystem exchange entry point.
            do { try Data("concurrent edit".utf8).write(to: url, options: .atomic) }
            catch { XCTFail("Could not simulate concurrent edit: \(error)") }
            return renameatx_np(fromFD, from, toFD, to, flags)
        })
        try writer.write(Data("download".utf8))
        let result = try writer.commit(expectedLength: 8)
        let recovery = try XCTUnwrap(result.recoveryURL)
        writer.cleanup()
        writer.cleanup()
        XCTAssertEqual(try Data(contentsOf: url), Data("download".utf8))
        XCTAssertEqual(try Data(contentsOf: recovery), Data("concurrent edit".utf8))
        XCTAssertEqual(recovery.deletingLastPathComponent(), directory)
    }

    func testRecoverySurvivesWriterDeinitializationAndSupportsMaximumLengthFilename() throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(String(repeating: "a", count: 255))
        try Data("original".utf8).write(to: url)
        var writer: S3DownloadWriter? = try S3DownloadWriter(destination: .init(url: url))
        try writer?.write(Data("download".utf8))
        let result = try XCTUnwrap(writer).commit(expectedLength: 8)
        let recovery = try XCTUnwrap(result.recoveryURL)
        writer = nil
        XCTAssertTrue(recovery.lastPathComponent.hasPrefix("AWSPlatform Recovery "))
        XCTAssertLessThan(recovery.lastPathComponent.utf8.count, 255)
        XCTAssertEqual(try Data(contentsOf: url), Data("download".utf8))
        XCTAssertEqual(try Data(contentsOf: recovery), Data("original".utf8))
    }

    func testRecoveryPathCollisionDoesNotOverwriteOrDeleteEitherFile() throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("document.txt")
        try Data("original".utf8).write(to: url)
        let identifier = UUID()
        let recovery = directory.appendingPathComponent("AWSPlatform Recovery \(identifier.uuidString)")
        try Data("existing recovery".utf8).write(to: recovery)
        XCTAssertThrowsError(try S3DownloadWriter(destination: .init(url: url), identifier: identifier))
        XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: recovery), Data("existing recovery".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testFailedExchangeDoesNotFallBackToDestructiveRenameAndCleansStaging() throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("document.txt")
        try Data("original".utf8).write(to: url)
        let writer = try S3DownloadWriter(destination: .init(url: url), rename: { _, _, _, _, flags in
            XCTAssertEqual(flags, UInt32(RENAME_SWAP))
            errno = ENOTSUP
            return -1
        })
        try writer.write(Data("download".utf8))
        XCTAssertThrowsError(try writer.commit(expectedLength: 8)) {
            XCTAssertEqual($0 as? S3TransferError, .destinationChanged)
        }
        writer.cleanup()
        XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.temporaryURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["document.txt"])
    }

    func testNewDestinationCreatedAtRenameBoundaryIsNeverOverwritten() throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("new.txt")
        let writer = try S3DownloadWriter(destination: .init(url: url), rename: { fromFD, from, toFD, to, flags in
            XCTAssertEqual(flags, UInt32(RENAME_EXCL))
            do { try Data("created concurrently".utf8).write(to: url) }
            catch { XCTFail("Could not create concurrent destination: \(error)") }
            return renameatx_np(fromFD, from, toFD, to, flags)
        })
        try writer.write(Data("download".utf8))
        XCTAssertThrowsError(try writer.commit(expectedLength: 8))
        writer.cleanup()
        XCTAssertEqual(try Data(contentsOf: url), Data("created concurrently".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["new.txt"])
    }

    func testRepeatedCleanupDoesNotDeleteAFileCreatedAfterStagingWasRemoved() throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("document.txt")
        var writer: S3DownloadWriter? = try S3DownloadWriter(destination: .init(url: url))
        let staging = try XCTUnwrap(writer).temporaryURL
        writer?.cleanup()
        try Data("new file".utf8).write(to: staging)
        writer?.cleanup()
        writer = nil
        XCTAssertEqual(try Data(contentsOf: staging), Data("new file".utf8))
    }

    func testCancellationBeforeCommitPreservesDestinationAndCleansStaging() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("document.txt")
        try Data("original".utf8).write(to: url)
        let task = Task {
            let writer = try S3DownloadWriter(destination: .init(url: url))
            try writer.write(Data("download".utf8))
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try writer.commit(expectedLength: 8)) { XCTAssertTrue($0 is CancellationError) }
            writer.cleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: writer.temporaryURL.path))
        }
        try await task.value
        XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8))
    }

    func testCancellationAtExchangeBoundaryNeverDeletesRecoveryCopy() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("document.txt")
        try Data("original".utf8).write(to: url)
        let task = Task {
            let writer = try S3DownloadWriter(destination: .init(url: url), rename: { fromFD, from, toFD, to, flags in
                withUnsafeCurrentTask { $0?.cancel() }
                return renameatx_np(fromFD, from, toFD, to, flags)
            })
            try writer.write(Data("download".utf8))
            let result = try writer.commit(expectedLength: 8)
            XCTAssertTrue(Task.isCancelled)
            writer.cleanup()
            return result
        }
        let result = try await task.value
        XCTAssertEqual(try Data(contentsOf: url), Data("download".utf8))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.recoveryURL)), Data("original".utf8))
    }
}
