import Foundation
import Darwin

struct S3FileFingerprint: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let seconds: Int64
    let nanoseconds: Int64

    init(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG else { throw S3TransferError.invalidFile }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        seconds = Int64(info.st_mtimespec.tv_sec)
        nanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }

    static func at(_ url: URL) throws -> Self? {
        guard url.isFileURL else { throw S3TransferError.invalidFile }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw S3TransferError.invalidFile
        }
        return try Self(info)
    }

    static func forHandle(_ handle: FileHandle) throws -> Self {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { throw S3TransferError.invalidFile }
        return try Self(info)
    }
}

struct S3LocalFile: Hashable, Sendable {
    static let maximumSize: Int64 = 5 * 1024 * 1024 * 1024
    let url: URL
    let fingerprint: S3FileFingerprint
    var size: Int64 { fingerprint.size }

    init(url: URL) throws {
        guard let fingerprint = try S3FileFingerprint.at(url) else { throw S3TransferError.invalidFile }
        guard fingerprint.size >= 0, fingerprint.size <= Self.maximumSize else { throw S3TransferError.tooLarge }
        self.url = url
        self.fingerprint = fingerprint
    }
}

/// A single-use, bounded file stream. Soto does not retry streaming request bodies.
actor S3UploadReader {
    static let chunkSize = 256 * 1024
    private let file: S3LocalFile
    private var handle: FileHandle?
    private var bytes: Int64 = 0
    private let progress: S3ProgressHandler

    init(file: S3LocalFile, progress: @escaping S3ProgressHandler) throws {
        self.file = file
        self.progress = progress
        let descriptor = open(file.url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw S3TransferError.invalidFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard try S3FileFingerprint.forHandle(handle) == file.fingerprint else {
            try? handle.close()
            throw S3TransferError.fileChanged
        }
        self.handle = handle
    }

    func next() async throws -> Data? {
        try Task.checkCancellation()
        guard let handle else { return nil }
        guard bytes < file.size else { return nil }
        let data = try handle.read(upToCount: Int(min(Int64(Self.chunkSize), file.size - bytes))) ?? Data()
        guard !data.isEmpty else { throw S3TransferError.fileChanged }
        bytes += Int64(data.count)
        try validate()
        await progress(.init(bytes: bytes, total: file.size))
        try Task.checkCancellation()
        return data
    }

    func validate() throws {
        guard let handle, try S3FileFingerprint.forHandle(handle) == file.fingerprint,
              try S3FileFingerprint.at(file.url) == file.fingerprint else { throw S3TransferError.fileChanged }
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    struct Chunks: AsyncSequence, Sendable {
        typealias Element = Data
        let reader: S3UploadReader
        struct AsyncIterator: AsyncIteratorProtocol {
            let reader: S3UploadReader
            mutating func next() async throws -> Data? { try await reader.next() }
        }
        func makeAsyncIterator() -> AsyncIterator { .init(reader: reader) }
    }
}

struct S3DownloadDestination: Hashable, Sendable {
    let url: URL
    let original: S3FileFingerprint?

    init(url: URL) throws {
        guard url.isFileURL, !url.lastPathComponent.isEmpty else { throw S3TransferError.invalidFile }
        self.url = url
        original = try S3FileFingerprint.at(url)
    }
}

/// Same-directory staging makes the final rename atomic, including across volumes.
final class S3DownloadWriter {
    let destination: S3DownloadDestination
    let temporaryURL: URL
    private var handle: FileHandle?
    private var committed = false
    private(set) var bytes: Int64 = 0

    init(destination: S3DownloadDestination) throws {
        self.destination = destination
        temporaryURL = destination.url.deletingLastPathComponent()
            .appendingPathComponent(".awsplatform-\(UUID().uuidString).part")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw S3TransferError.invalidFile }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit { cleanup() }

    func write(_ data: Data) throws {
        try Task.checkCancellation()
        guard let handle else { throw S3TransferError.invalidFile }
        try handle.write(contentsOf: data)
        bytes += Int64(data.count)
    }

    func commit(expectedLength: Int64?) throws {
        try Task.checkCancellation()
        if let expectedLength, bytes != expectedLength { throw S3TransferError.incompleteDownload }
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        guard try S3FileFingerprint.at(destination.url) == destination.original else {
            throw S3TransferError.destinationChanged
        }
        try Task.checkCancellation()
        let result: Int32
        if destination.original == nil {
            // A file created after the Save panel must not be silently replaced.
            result = renamex_np(temporaryURL.path, destination.url.path, UInt32(RENAME_EXCL))
        } else {
            result = rename(temporaryURL.path, destination.url.path)
        }
        guard result == 0 else { throw S3TransferError.destinationChanged }
        committed = true
    }

    func cleanup() {
        try? handle?.close()
        handle = nil
        if !committed { try? FileManager.default.removeItem(at: temporaryURL) }
    }
}
