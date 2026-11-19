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
            let lease = try S3UploadLease(root: root)
            let descriptor = try lease.createContent()
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
                guard fchmod(descriptor, S_IRUSR) == 0 else { throw S3TransferError.invalidFile }
                try output.close()
                let snapshot = S3UploadSnapshot(lease: lease,
                    checksum: Data(hash.finalize()).base64EncodedString())
                let prepared = try Self(sourceURL: url, snapshot: snapshot)
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
    let lease: S3UploadLease
    var url: URL { lease.contentURL }
    let checksum: String
    init(lease: S3UploadLease, checksum: String) {
        self.lease = lease
        self.checksum = checksum
    }
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

/// Private staging under the destination keeps the final rename on the same filesystem.
final class S3DownloadWriter {
    typealias Capacity = @Sendable (Int32) throws -> Int64
    typealias Rename = @Sendable (Int32, String, Int32, String, UInt32) -> Int32
    static let minimumFreeSpace: Int64 = 64 * 1024 * 1024
    let destination: S3DownloadDestination
    let temporaryURL: URL
    private var handle: FileHandle?
    private var committed = false
    private let stagingName: String
    private let stagingDirectory: Int32
    private let stagingIdentity: stat
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
        stagingName = ".awsplatform-download-\(identifier.uuidString)"
        temporaryName = destination.original == nil ? "partial" : "AWSPlatform Recovery \(identifier.uuidString)"
        temporaryURL = destination.directory.url.appendingPathComponent(stagingName, isDirectory: true)
            .appendingPathComponent(temporaryName)
        try destination.directory.validateMapping()
        let parent = destination.directory.descriptor
        let available = try capacity(parent)
        if let expectedLength, expectedLength < 0 || expectedLength > available - Self.minimumFreeSpace {
            throw S3TransferError.insufficientSpace
        }
        if destination.original != nil, try destination.directory.fingerprint(name: temporaryName) != nil {
            throw S3TransferError.invalidFile
        }
        guard mkdirat(parent, stagingName, 0o700) == 0 else { throw S3TransferError.invalidFile }
        var created = stat()
        guard fstatat(parent, stagingName, &created, AT_SYMLINK_NOFOLLOW) == 0,
              S3UploadLease.ownedPrivate(created, kind: S_IFDIR, permissions: [0o700]) else {
            throw S3TransferError.invalidFile
        }
        let directory = openat(parent, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var opened = stat()
        guard directory >= 0, fstat(directory, &opened) == 0,
              opened.st_dev == created.st_dev, opened.st_ino == created.st_ino,
              S3UploadLease.ownedPrivate(descriptor: directory, info: opened, kind: S_IFDIR, permissions: [0o700]) else {
            if directory >= 0 { close(directory) }
            Self.removeStagingDirectory(parent: parent, name: stagingName, expected: created)
            throw S3TransferError.invalidFile
        }
        let descriptor = openat(directory, temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        var temporaryInfo = stat()
        guard descriptor >= 0, fstat(descriptor, &temporaryInfo) == 0,
              S3UploadLease.ownedPrivate(descriptor: descriptor, info: temporaryInfo, kind: S_IFREG, permissions: [0o600]) else {
            if descriptor >= 0 {
                close(descriptor)
                _ = unlinkat(directory, temporaryName, 0)
            }
            close(directory)
            Self.removeStagingDirectory(parent: parent, name: stagingName, expected: opened)
            throw S3TransferError.invalidFile
        }
        stagingDirectory = directory
        stagingIdentity = opened
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit {
        cleanup()
        close(stagingDirectory)
    }

    func write(_ data: Data) throws {
        try Task.checkCancellation()
        guard let handle, !committed else { throw S3TransferError.invalidFile }
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
        guard let handle, !committed else { throw S3TransferError.invalidFile }
        try handle.synchronize()
        try destination.directory.validateMapping()
        guard try destination.directory.fingerprint(name: destination.url.lastPathComponent) == destination.original else {
            throw S3TransferError.destinationChanged
        }
        try Task.checkCancellation()
        let parent = destination.directory.descriptor
        guard Self.matchesStagingDirectory(parent: parent, name: stagingName, expected: stagingIdentity),
              S3UploadLease.hasNoExtendedACL(stagingDirectory),
              matchesTemporaryFile(handle) else { throw S3TransferError.destinationChanged }
        // An exchange keeps the displaced file, including edits made after the
        // fingerprint check. Never delete that recovery copy or fall back to a
        // destructive rename if the filesystem cannot exchange these entries.
        let isOverwrite = destination.original != nil
        let flags = UInt32(isOverwrite ? RENAME_SWAP : RENAME_EXCL)
        let result = rename(stagingDirectory, temporaryName, parent, destination.url.lastPathComponent, flags)
        guard result == 0 else { throw S3TransferError.destinationChanged }
        committed = true
        guard isOverwrite else { return .init() }
        // A name collision at publication leaves the displaced file in private staging.
        if renameatx_np(stagingDirectory, temporaryName, parent, temporaryName, UInt32(RENAME_EXCL)) == 0 {
            return .init(recoveryURL: destination.directory.url.appendingPathComponent(temporaryName))
        }
        return .init(recoveryURL: temporaryURL)
    }

    func cleanup() {
        guard let handle else { return }
        if !committed, matchesTemporaryFile(handle) {
            _ = unlinkat(stagingDirectory, temporaryName, 0)
        }
        try? handle.close()
        self.handle = nil
        Self.removeStagingDirectory(parent: destination.directory.descriptor, name: stagingName, expected: stagingIdentity)
    }

    private func matchesTemporaryFile(_ handle: FileHandle) -> Bool {
        var opened = stat(), entry = stat()
        return fstat(handle.fileDescriptor, &opened) == 0
            && fstatat(stagingDirectory, temporaryName, &entry, AT_SYMLINK_NOFOLLOW) == 0
            && opened.st_dev == entry.st_dev && opened.st_ino == entry.st_ino
            && S3UploadLease.ownedPrivate(descriptor: handle.fileDescriptor, info: entry,
                                          kind: S_IFREG, permissions: [0o600])
    }

    private static func matchesStagingDirectory(parent: Int32, name: String, expected: stat) -> Bool {
        var entry = stat()
        return fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) == 0
            && entry.st_dev == expected.st_dev && entry.st_ino == expected.st_ino
            && S3UploadLease.ownedPrivate(entry, kind: S_IFDIR, permissions: [0o700])
    }

    private static func removeStagingDirectory(parent: Int32, name: String, expected: stat) {
        if matchesStagingDirectory(parent: parent, name: name, expected: expected) {
            _ = unlinkat(parent, name, AT_REMOVEDIR)
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
