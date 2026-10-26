import Darwin
import Foundation
import XCTest
@testable import AWSPlatform

final class SSMScriptLeaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testExpiredUnexecutedHandoffIsRemovedAtAgeBoundary() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let expired = try pending(in: root, age: SSMScriptLease.maximumPendingAge + 1)
        let boundary = try pending(in: root, age: SSMScriptLease.maximumPendingAge)
        let recent = try pending(in: root, age: SSMScriptLease.maximumPendingAge - 1)
        let future = try pending(in: root, age: -60)
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: now)
        XCTAssertFalse(exists(expired))
        XCTAssertFalse(exists(boundary))
        XCTAssertTrue(exists(recent))
        XCTAssertTrue(exists(future))
    }

    func testInvalidCleanupDatePreservesPendingHandoff() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try pending(in: root)
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: Date(timeIntervalSince1970: .nan))
        XCTAssertTrue(exists(pending))
    }

    func testHeldStartupLockProtectsExpiredScriptUntilReleased() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try pending(in: root)
        let handle = try lockHandle(in: pending)
        XCTAssertEqual(flock(handle.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: now)
        XCTAssertTrue(exists(pending))
        try handle.close()
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: now)
        XCTAssertFalse(exists(pending))
    }

    func testOtherProcessLockProtectsScriptAndSIGKILLAllowsRecovery() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try pending(in: root)
        let handle = try lockHandle(in: pending)
        XCTAssertEqual(flock(handle.fileDescriptor, LOCK_EX | LOCK_NB), 0)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        child.environment = ["PATH": "/usr/bin:/bin"]
        child.standardInput = handle
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        try handle.close()
        XCTAssertTrue(child.isRunning)
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: now)
        XCTAssertTrue(exists(pending))
        XCTAssertEqual(kill(child.processIdentifier, SIGKILL), 0)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: now)
        XCTAssertFalse(exists(pending))
    }

    func testUnmarkedLegacyUnknownEntriesAndInvalidNamesArePreserved() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try pending(in: root)
        try FileManager.default.removeItem(at: legacy.appendingPathComponent(SSMScriptLease.markerName))
        let unknown = try pending(in: root)
        try Data("keep".utf8).write(to: unknown.appendingPathComponent("keep.txt"))
        let invalid = try pending(in: root)
        let renamed = invalid.deletingLastPathComponent().appendingPathComponent(SSMScriptLease.prefix + "not-a-uuid")
        try FileManager.default.moveItem(at: invalid, to: renamed)
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: now)
        for url in [legacy, unknown, renamed] { XCTAssertTrue(exists(url)) }
        XCTAssertEqual(try String(contentsOf: unknown.appendingPathComponent("keep.txt")), "keep")
    }

    func testUnrecognizedMarkerContentsArePreserved() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = try pending(in: root)
        let marker = pending.appendingPathComponent(SSMScriptLease.markerName)
        var other = SSMScriptLease.marker
        other[other.startIndex] ^= 1
        try other.write(to: marker)
        try setAge(marker, age: SSMScriptLease.maximumPendingAge + 1)
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: now)
        XCTAssertTrue(exists(pending))
        XCTAssertEqual(try Data(contentsOf: marker), other)
    }

    func testSymlinkedDirectoryScriptAndMarkerNeverFollowExternalTargets() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let target = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: target)
        let scriptLink = try pending(in: root)
        let markerLink = try pending(in: root)
        let linked = scriptLink.deletingLastPathComponent().appendingPathComponent(SSMScriptLease.prefix + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
        for (url, name) in [(scriptLink, SSMScriptLease.scriptName), (markerLink, SSMScriptLease.markerName)] {
            let replaced = url.appendingPathComponent(name)
            try FileManager.default.removeItem(at: replaced)
            try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: target)
        }
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: now)
        for url in [linked, scriptLink, markerLink] { XCTAssertTrue(exists(url)) }
        XCTAssertEqual(try String(contentsOf: target), "keep")
    }

    func testHardLinkedFilesAndNonPrivatePermissionsArePreserved() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var preserved: [URL] = []
        for name in [SSMScriptLease.scriptName, SSMScriptLease.markerName] {
            let pending = try pending(in: root)
            let source = pending.appendingPathComponent(name)
            let outside = root.appendingPathComponent(UUID().uuidString)
            XCTAssertEqual(link(source.path, outside.path), 0)
            preserved.append(pending)
        }
        for (name, permissions) in [("", mode_t(0o755)), (SSMScriptLease.markerName, 0o644), (SSMScriptLease.scriptName, 0o600)] {
            let pending = try pending(in: root)
            let changed = name.isEmpty ? pending : pending.appendingPathComponent(name)
            XCTAssertEqual(chmod(changed.path, permissions), 0)
            preserved.append(pending)
        }
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: now)
        for url in preserved { XCTAssertTrue(exists(url)) }
    }

    func testForeignOwnerAndMultipleLinksFailOwnershipCheck() {
        var info = stat()
        info.st_uid = getuid()
        info.st_mode = S_IFREG | 0o600
        info.st_nlink = 1
        XCTAssertTrue(SSMScriptLease.ownedPrivate(info, kind: S_IFREG, permissions: 0o600))
        info.st_uid = getuid() == 0 ? 1 : 0
        XCTAssertFalse(SSMScriptLease.ownedPrivate(info, kind: S_IFREG, permissions: 0o600))
        info.st_uid = getuid()
        info.st_nlink = 2
        XCTAssertFalse(SSMScriptLease.ownedPrivate(info, kind: S_IFREG, permissions: 0o600))
    }

    func testIndependentPendingLocksAndPartialPreparationDiscard() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let active = try SSMScriptLease(root: root)
        try active.writeScript("#!/bin/bash\nexit 0\n")
        try setAge(active.directory.appendingPathComponent(SSMScriptLease.markerName),
                   age: SSMScriptLease.maximumPendingAge + 1)
        let expired = try pending(in: root)
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: now)
        XCTAssertTrue(exists(active.directory))
        XCTAssertFalse(exists(expired))
        try active.releaseForHandoff()
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: now)
        XCTAssertFalse(exists(active.directory))
        let partial = try SSMScriptLease(root: root)
        partial.discard()
        XCTAssertFalse(exists(partial.directory))
    }

    func testDiscardUsesOriginalDirectoryDescriptorAfterRootPathIsReplaced() throws {
        let container = try directory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("root")
        let outside = container.appendingPathComponent("outside")
        for url in [root, outside] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let lease = try SSMScriptLease(root: root)
        try lease.writeScript("#!/bin/bash\nexit 0\n")
        let moved = container.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        let unrelated = outside.appendingPathComponent(SSMScriptLease.parentDirectoryName)
            .appendingPathComponent(lease.directory.lastPathComponent)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let keep = unrelated.appendingPathComponent(SSMScriptLease.scriptName)
        try Data("keep".utf8).write(to: keep)
        lease.discard()
        XCTAssertFalse(exists(moved.appendingPathComponent(SSMScriptLease.parentDirectoryName)
            .appendingPathComponent(lease.directory.lastPathComponent)))
        XCTAssertEqual(try String(contentsOf: keep), "keep")
    }

    private func pending(in root: URL, age: TimeInterval = SSMScriptLease.maximumPendingAge + 1) throws -> URL {
        let lease = try SSMScriptLease(root: root)
        try lease.writeScript("#!/bin/bash\nexit 0\n")
        try lease.releaseForHandoff()
        try setAge(lease.directory.appendingPathComponent(SSMScriptLease.markerName), age: age)
        return lease.directory
    }

    private func setAge(_ url: URL, age: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    private func directory() throws -> URL {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".tmp/ssm-script-cleanup/unit", isDirectory: true)
        let root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    private func lockHandle(in directory: URL) throws -> FileHandle {
        let file = open(directory.appendingPathComponent(SSMScriptLease.markerName).path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { throw CocoaError(.fileReadUnknown) }
        return FileHandle(fileDescriptor: file, closeOnDealloc: true)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}
