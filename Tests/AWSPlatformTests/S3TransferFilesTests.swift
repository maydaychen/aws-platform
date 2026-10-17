import Foundation
import XCTest
@testable import AWSPlatform

enum S3TransferFixtures {
    static func context(profileName: String = "test-profile", region: String? = "ap-southeast-1") -> S3TransferContext {
        let profile = AWSProfile(name: profileName, region: "us-east-1", ssoStartURL: nil,
            ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
        let scope = MonitoringScope(profile: profile,
            identity: .init(account: "111122223333", arn: "arn:aws:iam::111122223333:user/test", userID: "test"),
            region: "us-east-1", paths: AWSConfigurationPaths(environment: [
                "AWS_CONFIG_FILE": URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".tmp/s3-transfer/isolated-aws/config").path,
                "AWS_SHARED_CREDENTIALS_FILE": URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".tmp/s3-transfer/isolated-aws/credentials").path
            ]))
        return .init(scope: scope, bucket: "example-bucket", prefix: "folder/", knownRegion: region)
    }

    static func directory() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/s3-transfer/tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func file(in directory: URL, data: Data = Data("sample".utf8)) throws -> S3LocalFile {
        let url = directory.appendingPathComponent("file.txt")
        try data.write(to: url)
        return try S3LocalFile(url: url)
    }
}

final class S3TransferFilesTests: XCTestCase {
    func testKeyUsesPrefixAndUTF8LimitWithoutAcceptingPathsAsFilenames() throws {
        let context = S3TransferFixtures.context()
        XCTAssertEqual(try context.key(filename: "file.txt"), "folder/file.txt")
        for name in ["", ".", "..", "../file", "a/b", "bad\nname", String(repeating: "你", count: 400)] {
            XCTAssertThrowsError(try context.key(filename: name))
        }
        XCTAssertNoThrow(try S3TransferTarget.validateKey(String(repeating: "a", count: 1024)))
        XCTAssertThrowsError(try S3TransferTarget.validateKey(String(repeating: "a", count: 1025)))
    }

    func testUploadReadsBoundedChunksIncludingEmptyFile() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for count in [0, S3UploadReader.chunkSize * 2 + 17] {
            let data = Data(repeating: 42, count: count)
            let file = try S3TransferFixtures.file(in: directory, data: data)
            let reader = try S3UploadReader(file: file, progress: { _ in })
            var output = Data()
            for try await chunk in S3UploadReader.Chunks(reader: reader) {
                XCTAssertLessThanOrEqual(chunk.count, S3UploadReader.chunkSize)
                output.append(chunk)
            }
            try await reader.validate()
            await reader.close()
            XCTAssertEqual(output, data)
        }
    }

    func testChangedUploadFileAndSymlinkAreRejected() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        try Data("changed".utf8).write(to: file.url)
        XCTAssertThrowsError(try S3UploadReader(file: file, progress: { _ in }))
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file.url)
        XCTAssertThrowsError(try S3LocalFile(url: link))
        XCTAssertThrowsError(try S3LocalFile(url: directory))
    }

    func testOversizeUploadIsRejectedWithoutReadingFile() throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.truncate(atOffset: UInt64(S3LocalFile.maximumSize + 1))
        try handle.close()
        XCTAssertThrowsError(try S3LocalFile(url: file.url)) { XCTAssertEqual($0 as? S3TransferError, .tooLarge) }
    }

    func testUploadRejectsFileMutationBetweenChunks() async throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory, data: Data(repeating: 7, count: S3UploadReader.chunkSize + 10))
        let reader = try S3UploadReader(file: file, progress: { _ in })
        _ = try await reader.next()
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.truncate(atOffset: 10)
        try handle.close()
        do { _ = try await reader.next(); XCTFail("Changed file must not continue streaming") }
        catch { XCTAssertEqual(error as? S3TransferError, .fileChanged) }
        await reader.close()
    }

    func testFailedDownloadPreservesOriginalAndRemovesTemporaryFile() throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let writer = try S3DownloadWriter(destination: .init(url: file.url))
        try writer.write(Data("partial".utf8))
        XCTAssertThrowsError(try writer.commit(expectedLength: 100))
        writer.cleanup()
        XCTAssertEqual(try Data(contentsOf: file.url), Data("sample".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.temporaryURL.path))
    }

    func testSuccessfulDownloadAtomicallyReplacesAndTruncatesOriginal() throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let writer = try S3DownloadWriter(destination: .init(url: file.url))
        try writer.write(Data("ok".utf8))
        let result = try writer.commit(expectedLength: 2)
        writer.cleanup()
        XCTAssertEqual(try Data(contentsOf: file.url), Data("ok".utf8))
        XCTAssertEqual(result.recoveryURL, writer.temporaryURL)
        XCTAssertEqual(try Data(contentsOf: writer.temporaryURL), Data("sample".utf8))
    }

    func testEmptyDownloadAndNewDestinationConflict() throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("empty")
        let writer = try S3DownloadWriter(destination: .init(url: url))
        XCTAssertNil(try writer.commit(expectedLength: 0).recoveryURL)
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
        let newURL = directory.appendingPathComponent("new")
        let conflict = try S3DownloadWriter(destination: .init(url: newURL))
        try Data("created later".utf8).write(to: newURL)
        XCTAssertThrowsError(try conflict.commit(expectedLength: 0))
        conflict.cleanup()
        XCTAssertEqual(try Data(contentsOf: newURL), Data("created later".utf8))
    }

    func testChangedExistingDestinationIsPreserved() throws {
        let directory = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try S3TransferFixtures.file(in: directory)
        let writer = try S3DownloadWriter(destination: .init(url: file.url))
        try Data("user edit".utf8).write(to: file.url)
        XCTAssertThrowsError(try writer.commit(expectedLength: 0))
        writer.cleanup()
        XCTAssertEqual(try Data(contentsOf: file.url), Data("user edit".utf8))
    }
}
