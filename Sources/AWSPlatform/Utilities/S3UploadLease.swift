import Darwin
import Foundation

/// The locked marker distinguishes our abandoned upload copies from active or unrelated files.
final class S3UploadLease: @unchecked Sendable {
    static let prefix = "awsplatform-upload-"
    static let markerName = ".awsplatform-upload-lease"
    static let marker = Data("AWSPlatform upload snapshot v1\n".utf8)
    let directory: URL
    let contentURL: URL
    private let root: Int32
    private let descriptor: Int32
    private let lock: Int32
    private let name: String

    init(root url: URL) throws {
        let canonicalRoot = url.resolvingSymlinksInPath()
        root = open(canonicalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw S3TransferError.invalidFile }
        name = Self.prefix + UUID().uuidString
        directory = canonicalRoot.appendingPathComponent(name, isDirectory: true)
        contentURL = directory.appendingPathComponent("content")
        guard mkdirat(root, name, S_IRWXU) == 0 else { close(root); throw S3TransferError.invalidFile }
        descriptor = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var directoryInfo = stat()
        guard descriptor >= 0, fstat(descriptor, &directoryInfo) == 0,
              Self.ownedPrivate(descriptor: descriptor, info: directoryInfo, kind: S_IFDIR, permissions: [0o700]) else {
            if descriptor >= 0 { close(descriptor) }
            _ = unlinkat(root, name, AT_REMOVEDIR); close(root)
            throw S3TransferError.invalidFile
        }
        lock = openat(descriptor, Self.markerName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        var lockInfo = stat()
        guard lock >= 0, fstat(lock, &lockInfo) == 0,
              Self.ownedPrivate(descriptor: lock, info: lockInfo, kind: S_IFREG, permissions: [0o600]) else {
            if lock >= 0 { close(lock); _ = unlinkat(descriptor, Self.markerName, 0) }
            close(descriptor); _ = unlinkat(root, name, AT_REMOVEDIR); close(root)
            throw S3TransferError.invalidFile
        }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock); _ = unlinkat(descriptor, Self.markerName, 0)
            close(descriptor); _ = unlinkat(root, name, AT_REMOVEDIR); close(root)
            throw S3TransferError.invalidFile
        }
        let written = Self.marker.withUnsafeBytes { Darwin.write(lock, $0.baseAddress, $0.count) }
        guard written == Self.marker.count else {
            close(lock); _ = unlinkat(descriptor, Self.markerName, 0)
            close(descriptor); _ = unlinkat(root, name, AT_REMOVEDIR); close(root)
            throw S3TransferError.invalidFile
        }
    }

    func createContent() throws -> Int32 {
        let result = openat(descriptor, "content", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard result >= 0 else { throw S3TransferError.invalidFile }
        var info = stat()
        guard fstat(result, &info) == 0,
              Self.ownedPrivate(descriptor: result, info: info, kind: S_IFREG, permissions: [0o600]) else {
            close(result)
            _ = unlinkat(descriptor, "content", 0)
            throw S3TransferError.invalidFile
        }
        return result
    }

    deinit {
        Self.removeKnownSnapshot(root: root, name: name, directory: descriptor, marker: lock)
        close(lock)
        close(descriptor)
        close(root)
    }

    /// Startup work is bounded and runs away from the UI actor. Unmarked older copies are preserved.
    static func cleanupOrphans(in root: URL = FileManager.default.temporaryDirectory) async {
        await Task.detached(priority: .utility) { cleanupOrphansSynchronously(in: root) }.value
    }

    static func cleanupOrphansSynchronously(in url: URL, beforeContentIsolation: (() -> Void)? = nil) {
        let root = open(url.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return }
        defer { close(root) }
        guard let entries = entries(in: root, limit: 4096) else { return }
        for name in entries where validName(name) {
            let directory = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { continue }
            defer { close(directory) }
            let marker = openat(directory, markerName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard marker >= 0 else { continue }
            defer { close(marker) }
            guard flock(marker, LOCK_EX | LOCK_NB) == 0 else { continue }
            removeKnownSnapshot(root: root, name: name, directory: directory, marker: marker,
                                beforeContentIsolation: beforeContentIsolation)
        }
    }

    private static func validName(_ name: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = String(name.dropFirst(prefix.count))
        return UUID(uuidString: suffix)?.uuidString == suffix
    }

    static func ownedPrivate(_ info: stat, kind: mode_t, permissions: Set<mode_t>) -> Bool {
        info.st_uid == getuid() && info.st_mode & S_IFMT == kind
            && permissions.contains(info.st_mode & 0o7777)
            && (kind == S_IFDIR || info.st_nlink == 1)
    }

    static func ownedPrivate(descriptor: Int32, info: stat, kind: mode_t, permissions: Set<mode_t>) -> Bool {
        ownedPrivate(info, kind: kind, permissions: permissions) && hasNoExtendedACL(descriptor)
    }

    static func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            return errno == ENOENT
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) != 0
    }

    private static func removeKnownSnapshot(root: Int32, name: String, directory: Int32, marker: Int32,
                                           beforeContentIsolation: (() -> Void)? = nil) {
        var directoryInfo = stat(), markerInfo = stat()
        guard fstat(directory, &directoryInfo) == 0,
              ownedPrivate(directoryInfo, kind: S_IFDIR, permissions: [0o700]),
              matches(root, name, directoryInfo),
              fstat(marker, &markerInfo) == 0,
              ownedPrivate(markerInfo, kind: S_IFREG, permissions: [0o600]),
              markerInfo.st_size == Self.marker.count,
              matches(directory, markerName, markerInfo),
              let names = entries(in: directory, limit: 3),
              Set(names).isSubset(of: [markerName, "content"]), names.contains(markerName) else { return }
        var data = Data(count: Self.marker.count)
        let count = data.withUnsafeMutableBytes { pread(marker, $0.baseAddress, $0.count, 0) }
        guard count == Self.marker.count, data == Self.marker else { return }
        if names.contains("content") {
            var content = stat()
            guard fstatat(directory, "content", &content, AT_SYMLINK_NOFOLLOW) == 0,
                  ownedPrivate(content, kind: S_IFREG, permissions: [0o400, 0o600]),
                  content.st_size >= 0, content.st_size <= S3LocalFile.maximumSize,
                  matches(root, name, directoryInfo), matches(directory, markerName, markerInfo) else { return }
            guard isolateAndRemoveContent(in: directory, expected: content,
                                          beforeIsolation: beforeContentIsolation) else { return }
        }
        guard matches(root, name, directoryInfo), matches(directory, markerName, markerInfo),
              unlinkat(directory, markerName, 0) == 0 else { return }
        if matches(root, name, directoryInfo) { _ = unlinkat(root, name, AT_REMOVEDIR) }
    }

    private static func isolateAndRemoveContent(in directory: Int32, expected: stat,
                                                beforeIsolation: (() -> Void)?) -> Bool {
        let name = ".cleanup-" + UUID().uuidString
        guard mkdirat(directory, name, S_IRWXU) == 0 else { return false }
        let quarantine = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard quarantine >= 0 else { return false }
        defer { close(quarantine) }
        var isolatedDirectory = stat()
        guard fstat(quarantine, &isolatedDirectory) == 0,
              ownedPrivate(isolatedDirectory, kind: S_IFDIR, permissions: [0o700]) else { return false }
        var removed = false
        defer {
            // An unsuccessful claim leaves this unknown entry as a preservation
            // marker: a later startup must not classify a restored replacement as ours.
            if removed, matches(directory, name, isolatedDirectory) { _ = unlinkat(directory, name, AT_REMOVEDIR) }
        }
        beforeIsolation?()
        // Claim the directory entry before inspecting it again. A replaced entry must
        // be restored, or retained in quarantine if its original name is now occupied.
        guard renameatx_np(directory, "content", quarantine, "content", UInt32(RENAME_EXCL)) == 0 else { return false }
        let file = openat(quarantine, "content", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        func restore() { _ = renameatx_np(quarantine, "content", directory, "content", UInt32(RENAME_EXCL)) }
        guard file >= 0 else { restore(); return false }
        defer { close(file) }
        var actual = stat()
        guard fstat(file, &actual) == 0, actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino,
              ownedPrivate(actual, kind: S_IFREG, permissions: [0o400, 0o600]),
              actual.st_size >= 0, actual.st_size <= S3LocalFile.maximumSize,
              matches(quarantine, "content", actual), matches(directory, name, isolatedDirectory),
              unlinkat(quarantine, "content", 0) == 0 else { restore(); return false }
        removed = true
        return true
    }

    private static func matches(_ directory: Int32, _ name: String, _ expected: stat) -> Bool {
        var current = stat()
        return fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_dev == expected.st_dev && current.st_ino == expected.st_ino
            && current.st_mode & S_IFMT == expected.st_mode & S_IFMT
    }

    private static func entries(in descriptor: Int32, limit: Int) -> [String]? {
        // A separate directory description avoids sharing an enumeration offset with callers.
        let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { return nil }
        guard let stream = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            guard result.count < limit else { return nil }
            result.append(name)
        }
        return result
    }
}
