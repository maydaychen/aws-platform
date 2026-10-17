import Foundation
import Darwin
import CryptoKit

struct S3FileFingerprint: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let seconds: Int64
    let nanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    init(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG else { throw S3TransferError.invalidFile }
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        seconds = Int64(info.st_mtimespec.tv_sec)
        nanoseconds = Int64(info.st_mtimespec.tv_nsec)
        changeSeconds = Int64(info.st_ctimespec.tv_sec)
        changeNanoseconds = Int64(info.st_ctimespec.tv_nsec)
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
    private let snapshot: S3UploadSnapshot?
    var size: Int64 { fingerprint.size }
    var contentURL: URL { snapshot?.url ?? url }
    var checksumSHA256: String? { snapshot?.checksum }

    init(url: URL) throws {
        guard let fingerprint = try S3FileFingerprint.at(url) else { throw S3TransferError.invalidFile }
        guard fingerprint.size >= 0, fingerprint.size <= Self.maximumSize else { throw S3TransferError.tooLarge }
        self.url = url
        self.fingerprint = fingerprint
        snapshot = nil
    }

    private init(sourceURL: URL, snapshot: S3UploadSnapshot) throws {
        url = sourceURL
        guard let fingerprint = try S3FileFingerprint.at(snapshot.url) else { throw S3TransferError.invalidFile }
        self.fingerprint = fingerprint
        self.snapshot = snapshot
    }

    static func prepare(url: URL, temporaryRoot: URL? = nil) async throws -> Self {
        let task = Task.detached { () async throws -> Self in
            try Task.checkCancellation()
            let source = try S3LocalFile(url: url)
            let reader = try S3UploadReader(file: source, progress: { _ in })
            let root = temporaryRoot ?? FileManager.default.temporaryDirectory
            let directory = root.appendingPathComponent("awsplatform-upload-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let target = directory.appendingPathComponent("content")
            var retained = false
            defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
            let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { await reader.close(); throw S3TransferError.invalidFile }
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                guard source.size <= (try S3DownloadWriter.availableCapacity(descriptor)) - S3DownloadWriter.minimumFreeSpace else {
                    throw S3TransferError.insufficientSpace
                }
                var hash = SHA256()
                for try await chunk in S3UploadReader.Chunks(reader: reader) {
                    try Task.checkCancellation()
                    guard Int64(chunk.count) <= (try S3DownloadWriter.availableCapacity(descriptor)) - S3DownloadWriter.minimumFreeSpace else {
                        throw S3TransferError.insufficientSpace
                    }
                    hash.update(data: chunk)
                    try output.write(contentsOf: chunk)
                }
                try await reader.validate()
                await reader.close()
                try output.close()
                guard chmod(target.path, S_IRUSR) == 0 else { throw S3TransferError.invalidFile }
                let snapshot = S3UploadSnapshot(directory: directory, url: target,
                    checksum: Data(hash.finalize()).base64EncodedString())
                let prepared = try Self(sourceURL: url, snapshot: snapshot)
                retained = true
                try Task.checkCancellation()
                return prepared
            } catch {
                await reader.close()
                try? output.close()
                throw error
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

private final class S3UploadSnapshot: Hashable, @unchecked Sendable {
    let directory: URL
    let url: URL
    let checksum: String
    init(directory: URL, url: URL, checksum: String) {
        self.directory = directory
        self.url = url
        self.checksum = checksum
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    static func == (lhs: S3UploadSnapshot, rhs: S3UploadSnapshot) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
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
        let descriptor = open(file.contentURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
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
              try S3FileFingerprint.at(file.contentURL) == file.fingerprint else { throw S3TransferError.fileChanged }
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
    let directory: S3DestinationDirectory

    init(url: URL) throws {
        guard url.isFileURL, !url.lastPathComponent.isEmpty else { throw S3TransferError.invalidFile }
        self.url = url
        directory = try S3DestinationDirectory(url: url.deletingLastPathComponent())
        original = try directory.fingerprint(name: url.lastPathComponent)
    }
}

final class S3DestinationDirectory: Hashable, @unchecked Sendable {
    let descriptor: Int32
    let url: URL
    private let route: URL
    private let device: Int32
    private let inode: UInt64

    init(url: URL) throws {
        route = url
        self.url = url.resolvingSymlinksInPath()
        descriptor = open(self.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw S3TransferError.invalidFile }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { close(descriptor); throw S3TransferError.invalidFile }
        device = info.st_dev
        inode = info.st_ino
    }

    deinit { close(descriptor) }

    func validateMapping() throws {
        var info = stat()
        guard stat(route.path, &info) == 0, info.st_dev == device, info.st_ino == inode else {
            throw S3TransferError.destinationChanged
        }
    }

    func fingerprint(name: String) throws -> S3FileFingerprint? {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw S3TransferError.invalidFile
        }
        return try S3FileFingerprint(info)
    }

    static func == (lhs: S3DestinationDirectory, rhs: S3DestinationDirectory) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Same-directory staging makes the final rename atomic, including across volumes.
final class S3DownloadWriter {
    typealias Capacity = @Sendable (Int32) throws -> Int64
    typealias Rename = @Sendable (Int32, String, Int32, String, UInt32) -> Int32
    static let minimumFreeSpace: Int64 = 64 * 1024 * 1024
    let destination: S3DownloadDestination
    let temporaryURL: URL
    private var handle: FileHandle?
    private var committed = false
    private var ownsTemporary = false
    private let temporaryName: String
    private let expectedLength: Int64?
    private let capacity: Capacity
    private let rename: Rename
    private(set) var bytes: Int64 = 0

    init(destination: S3DownloadDestination, expectedLength: Int64? = nil,
         capacity: @escaping Capacity = { try S3DownloadWriter.availableCapacity($0) },
         identifier: UUID = UUID(),
         rename: @escaping Rename = { renameatx_np($0, $1, $2, $3, $4) }) throws {
        self.destination = destination
        self.expectedLength = expectedLength
        self.capacity = capacity
        self.rename = rename
        temporaryName = destination.original == nil
            ? ".awsplatform-\(identifier.uuidString).part"
            : "AWSPlatform Recovery \(identifier.uuidString)"
        temporaryURL = destination.directory.url.appendingPathComponent(temporaryName)
        try destination.directory.validateMapping()
        let available = try capacity(destination.directory.descriptor)
        if let expectedLength, expectedLength < 0 || expectedLength > available - Self.minimumFreeSpace {
            throw S3TransferError.insufficientSpace
        }
        let descriptor = openat(destination.directory.descriptor, temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw S3TransferError.invalidFile }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        ownsTemporary = true
    }

    deinit { cleanup() }

    func write(_ data: Data) throws {
        try Task.checkCancellation()
        guard let handle else { throw S3TransferError.invalidFile }
        if let expectedLength, Int64(data.count) > expectedLength - bytes { throw S3TransferError.incompleteDownload }
        guard Int64(data.count) <= (try capacity(destination.directory.descriptor)) - Self.minimumFreeSpace else {
            throw S3TransferError.insufficientSpace
        }
        try handle.write(contentsOf: data)
        bytes += Int64(data.count)
    }

    @discardableResult
    func commit(expectedLength: Int64?) throws -> S3DownloadResult {
        try Task.checkCancellation()
        if let expectedLength, bytes != expectedLength { throw S3TransferError.incompleteDownload }
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        try destination.directory.validateMapping()
        guard try destination.directory.fingerprint(name: destination.url.lastPathComponent) == destination.original else {
            throw S3TransferError.destinationChanged
        }
        try Task.checkCancellation()
        // An exchange keeps the displaced file, including edits made after the
        // fingerprint check. Never delete that recovery copy or fall back to a
        // destructive rename if the filesystem cannot exchange these entries.
        let isOverwrite = destination.original != nil
        let flags = UInt32(isOverwrite ? RENAME_SWAP : RENAME_EXCL)
        let result = rename(destination.directory.descriptor, temporaryName,
            destination.directory.descriptor, destination.url.lastPathComponent, flags)
        guard result == 0 else { throw S3TransferError.destinationChanged }
        committed = true
        return .init(recoveryURL: isOverwrite ? temporaryURL : nil)
    }

    func cleanup() {
        try? handle?.close()
        handle = nil
        if ownsTemporary, !committed {
            ownsTemporary = false
            unlinkat(destination.directory.descriptor, temporaryName, 0)
        }
    }

    static func availableCapacity(_ descriptor: Int32) throws -> Int64 {
        var info = statfs()
        guard fstatfs(descriptor, &info) == 0 else { throw S3TransferError.insufficientSpace }
        let blocks = Int64(clamping: info.f_bavail)
        let (bytes, overflow) = blocks.multipliedReportingOverflow(by: Int64(info.f_bsize))
        return overflow ? Int64.max : bytes
    }
}
