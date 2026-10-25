import Darwin
import Foundation

/// Marks pending handoffs only. Running scripts remove these files before obtaining credentials.
final class SSMScriptLease {
    static let prefix = "AWSPlatform-SSM-"
    static let markerName = ".awsplatform-ssm-lease"
    static let scriptName = "Connect.command"
    static let marker = Data("AWSPlatform pending SSM script v1\n".utf8)
    static let maximumPendingAge: TimeInterval = 24 * 60 * 60
    private static let scanCursor = RootScanCursor()
    let directory: URL
    let directoryIdentity: String
    var scriptURL: URL { directory.appendingPathComponent(Self.scriptName) }
    private let root: Int32
    private let descriptor: Int32
    private let lock: Int32
    private let name: String

    init(root url: URL, beforeMarkerCreation: ((URL) -> Void)? = nil,
         beforeMarkerLock: ((URL) -> Void)? = nil) throws {
        let canonicalRoot = url.resolvingSymlinksInPath()
        let root = open(canonicalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let name = Self.prefix + UUID().uuidString
        let directory = canonicalRoot.appendingPathComponent(name, isDirectory: true)
        guard mkdirat(root, name, S_IRWXU) == 0 else { close(root); throw CocoaError(.fileWriteUnknown) }
        var created = stat()
        guard fstatat(root, name, &created, AT_SYMLINK_NOFOLLOW) == 0 else {
            close(root); throw CocoaError(.fileWriteUnknown)
        }
        let descriptor = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            Self.removeCreatedDirectory(root: root, name: name, expected: created)
            close(root); throw CocoaError(.fileWriteUnknown)
        }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_dev == created.st_dev, opened.st_ino == created.st_ino,
              Self.ownedPrivate(opened, kind: S_IFDIR, permissions: 0o700) else {
            close(descriptor); Self.removeCreatedDirectory(root: root, name: name, expected: created)
            close(root); throw CocoaError(.fileWriteUnknown)
        }
        let directoryIdentity = "\(UInt32(bitPattern: opened.st_dev)):\(opened.st_ino)"
        beforeMarkerCreation?(directory)
        let lock = openat(descriptor, Self.markerName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                      S_IRUSR | S_IWUSR)
        guard lock >= 0 else {
            close(descriptor); Self.removeCreatedDirectory(root: root, name: name, expected: created); close(root)
            throw CocoaError(.fileWriteUnknown)
        }
        beforeMarkerLock?(directory.appendingPathComponent(Self.markerName))
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            Self.removeCreatedMarker(in: descriptor, marker: lock)
            close(lock); close(descriptor); Self.removeCreatedDirectory(root: root, name: name, expected: created); close(root)
            throw CocoaError(.fileWriteUnknown)
        }
        do { try Self.write(Self.marker, to: lock) }
        catch {
            Self.removeCreatedMarker(in: descriptor, marker: lock)
            close(lock); close(descriptor)
            Self.removeCreatedDirectory(root: root, name: name, expected: created); close(root)
            throw error
        }
        // Throwing before this ownership transfer cannot invoke deinit with already closed descriptors.
        self.root = root
        self.descriptor = descriptor
        self.lock = lock
        self.name = name
        self.directory = directory
        self.directoryIdentity = directoryIdentity
    }

    deinit { close(lock); close(descriptor); close(root) }

    private static func removeCreatedDirectory(root: Int32, name: String, expected: stat) {
        // rmdir never recursively removes unexpected entries introduced during preparation.
        if matches(root, name, expected) { _ = unlinkat(root, name, AT_REMOVEDIR) }
    }

    private static func removeCreatedMarker(in directory: Int32, marker: Int32) {
        var info = stat()
        guard fstat(marker, &info) == 0, ownedPrivate(info, kind: S_IFREG, permissions: 0o600),
              matches(directory, markerName, info) else { return }
        _ = unlinkat(directory, markerName, 0)
    }

    func writeScript(_ script: String) throws {
        let file = openat(descriptor, Self.scriptName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRWXU)
        guard file >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(file) }
        try Self.write(Data(script.utf8), to: file)
    }

    func releaseForHandoff() throws {
        guard flock(lock, LOCK_UN) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func discard() {
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { _ = flock(lock, LOCK_UN) }
        Self.removeKnownScript(root: root, name: name, directory: descriptor, marker: lock)
    }

    static func cleanupOrphans(in root: URL = FileManager.default.temporaryDirectory,
                               now: Date = Date(), maximumAge: TimeInterval = maximumPendingAge,
                               entryLimit: Int = 4096, maximumBatches: Int = 16) async {
        guard maximumBatches > 0 else { return }
        await Task.detached(priority: .utility) {
            for _ in 0..<min(maximumBatches, 16) {
                guard !Task.isCancelled else { return }
                guard cleanupOrphansSynchronously(in: root, now: now, maximumAge: maximumAge, entryLimit: entryLimit) else { return }
                await Task.yield()
            }
        }.value
    }

    @discardableResult
    static func cleanupOrphansSynchronously(in url: URL, now: Date = Date(),
                                            maximumAge: TimeInterval = maximumPendingAge,
                                            entryLimit: Int = 4096,
                                            beforeContentIsolation: (() -> Void)? = nil) -> Bool {
        guard maximumAge.isFinite, maximumAge >= 0, now.timeIntervalSince1970.isFinite, entryLimit > 0 else { return false }
        let root = open(url.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return false }
        defer { close(root) }
        guard let batch = scanCursor.next(in: root, limit: min(entryLimit, 4096)) else { return false }
        for name in batch.names {
            let directory = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { continue }
            defer { close(directory) }
            let marker = openat(directory, markerName, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard marker >= 0 else { continue }
            defer { close(marker) }
            guard flock(marker, LOCK_EX | LOCK_NB) == 0 else { continue }
            var info = stat()
            guard fstat(marker, &info) == 0 else { continue }
            let created = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            guard now.timeIntervalSince1970 - created >= maximumAge else { continue }
            removeKnownScript(root: root, name: name, directory: directory, marker: marker,
                              beforeContentIsolation: beforeContentIsolation)
        }
        return batch.more
    }

    static func ownedPrivate(_ info: stat, kind: mode_t, permissions: mode_t) -> Bool {
        info.st_uid == getuid() && info.st_mode & S_IFMT == kind
            && info.st_mode & 0o7777 == permissions && (kind == S_IFDIR || info.st_nlink == 1)
    }

    private static func validName(_ name: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count)))?.uuidString == String(name.dropFirst(prefix.count))
    }

    private static func removeKnownScript(root: Int32, name: String, directory: Int32, marker: Int32,
                                          beforeContentIsolation: (() -> Void)? = nil) {
        var directoryInfo = stat(), markerInfo = stat()
        guard fstat(directory, &directoryInfo) == 0,
              ownedPrivate(directoryInfo, kind: S_IFDIR, permissions: 0o700), matches(root, name, directoryInfo),
              fstat(marker, &markerInfo) == 0, ownedPrivate(markerInfo, kind: S_IFREG, permissions: 0o600),
              markerInfo.st_size == Self.marker.count, matches(directory, markerName, markerInfo),
              let names = entries(in: directory, limit: 3),
              Set(names).isSubset(of: [markerName, scriptName]), names.contains(markerName) else { return }
        var data = Data(count: Self.marker.count)
        let count = data.withUnsafeMutableBytes { pread(marker, $0.baseAddress, $0.count, 0) }
        guard count == Self.marker.count, data == Self.marker else { return }
        if names.contains(scriptName) {
            var script = stat()
            guard fstatat(directory, scriptName, &script, AT_SYMLINK_NOFOLLOW) == 0,
                  ownedPrivate(script, kind: S_IFREG, permissions: 0o700),
                  script.st_size >= 0, script.st_size <= 1024 * 1024,
                  matches(root, name, directoryInfo), matches(directory, markerName, markerInfo),
                  isolateAndRemove(in: directory, fileName: scriptName, expected: script,
                                   beforeIsolation: beforeContentIsolation) else { return }
        }
        guard matches(root, name, directoryInfo), matches(directory, markerName, markerInfo),
              isolateAndRemove(in: directory, fileName: markerName, expected: markerInfo, beforeIsolation: nil) else { return }
        if matches(root, name, directoryInfo) { _ = unlinkat(root, name, AT_REMOVEDIR) }
    }

    private static func isolateAndRemove(in directory: Int32, fileName: String, expected: stat,
                                          beforeIsolation: (() -> Void)?) -> Bool {
        let name = ".cleanup-" + UUID().uuidString
        guard mkdirat(directory, name, S_IRWXU) == 0 else { return false }
        let quarantine = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard quarantine >= 0 else { return false }
        defer { close(quarantine) }
        var directoryInfo = stat()
        guard fstat(quarantine, &directoryInfo) == 0,
              ownedPrivate(directoryInfo, kind: S_IFDIR, permissions: 0o700) else { return false }
        var removed = false
        defer {
            // Failed claims keep a preservation entry so later scans will not delete replacements.
            if removed, matches(directory, name, directoryInfo) { _ = unlinkat(directory, name, AT_REMOVEDIR) }
        }
        beforeIsolation?()
        guard renameatx_np(directory, fileName, quarantine, fileName, UInt32(RENAME_EXCL)) == 0 else { return false }
        let file = openat(quarantine, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        func restore() { _ = renameatx_np(quarantine, fileName, directory, fileName, UInt32(RENAME_EXCL)) }
        guard file >= 0 else { restore(); return false }
        defer { close(file) }
        var actual = stat()
        let permissions: mode_t = fileName == markerName ? 0o600 : 0o700
        guard fstat(file, &actual) == 0, same(actual, expected),
              ownedPrivate(actual, kind: S_IFREG, permissions: permissions),
              matches(quarantine, fileName, actual), matches(directory, name, directoryInfo),
              unlinkat(quarantine, fileName, 0) == 0 else { restore(); return false }
        removed = true
        return true
    }

    private static func same(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func matches(_ directory: Int32, _ name: String, _ expected: stat) -> Bool {
        var current = stat()
        return fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_dev == expected.st_dev && current.st_ino == expected.st_ino
            && current.st_mode & S_IFMT == expected.st_mode & S_IFMT
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
    }

    private static func entries(in descriptor: Int32, limit: Int) -> [String]? {
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

    /// One root and one descriptor, shared safely by startup and subsequent Connect scans.
    private final class RootScanCursor: @unchecked Sendable {
        private let lock = NSLock()
        private var stream: UnsafeMutablePointer<DIR>?
        private var identity: (dev_t, ino_t)?

        deinit { reset() }

        func next(in root: Int32, limit: Int) -> (names: [String], more: Bool)? {
            lock.lock()
            defer { lock.unlock() }
            var info = stat()
            guard fstat(root, &info) == 0 else { reset(); return nil }
            if identity?.0 != info.st_dev || identity?.1 != info.st_ino {
                reset()
                let copy = openat(root, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                guard copy >= 0 else { return nil }
                guard let opened = fdopendir(copy) else { close(copy); return nil }
                stream = opened
                identity = (info.st_dev, info.st_ino)
            }
            guard let stream else { return nil }
            var names: [String] = []
            for _ in 0..<limit {
                errno = 0
                guard let entry = readdir(stream) else {
                    let failed = errno != 0
                    reset()
                    return failed ? nil : (names, false)
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if SSMScriptLease.validName(name) { names.append(name) }
            }
            return (names, true)
        }

        private func reset() {
            if let stream { closedir(stream) }
            stream = nil
            identity = nil
        }
    }
}
