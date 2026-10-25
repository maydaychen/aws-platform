import Darwin
import Foundation
import XCTest
@testable import AWSPlatform

final class S3UploadLeaseTests: XCTestCase {
    func testActiveLeaseSurvivesCleanupAndReleaseRemovesOnlyItsSnapshot() throws {
        let root = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        var lease: S3UploadLease? = try S3UploadLease(root: root)
        let directory = try XCTUnwrap(lease).directory
        let descriptor = try XCTUnwrap(lease).createContent()
        XCTAssertEqual(write(descriptor, "snapshot", 8), 8)
        close(descriptor)
        S3UploadLease.cleanupOrphansSynchronously(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        lease = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try String(contentsOf: unrelated), "keep")
    }

    func testUnlockedOrphanWithKnownMarkerIsRemovedIncludingPartiallyWrittenCopy() throws {
        let root = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for permissions in [0o400, 0o600] {
            let directory = try orphan(in: root)
            let content = directory.appendingPathComponent("content")
            try Data("partial snapshot".utf8).write(to: content)
            XCTAssertEqual(chmod(content.path, mode_t(permissions)), 0)
            S3UploadLease.cleanupOrphansSynchronously(in: root)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
        let beforeContent = try orphan(in: root)
        S3UploadLease.cleanupOrphansSynchronously(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: beforeContent.path))
    }

    func testLeaseHeldByAnotherProcessIsSkippedUntilThatProcessExits() throws {
        let root = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try orphan(in: root)
        let marker = open(directory.appendingPathComponent(S3UploadLease.markerName).path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(marker, 0)
        guard marker >= 0 else { return }
        let handle = FileHandle(fileDescriptor: marker, closeOnDealloc: true)
        XCTAssertEqual(flock(marker, LOCK_EX | LOCK_NB), 0)
        // stdin duplicates the already locked description into this local helper process.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        child.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
        child.standardInput = handle
        try child.run()
        try handle.close()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        S3UploadLease.cleanupOrphansSynchronously(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        child.terminate()
        child.waitUntilExit()
        S3UploadLease.cleanupOrphansSynchronously(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testUnmarkedLegacyAndUnknownEntriesArePreserved() throws {
        let root = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try orphan(in: root)
        try FileManager.default.removeItem(at: legacy.appendingPathComponent(S3UploadLease.markerName))
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("content"))
        let unknown = try orphan(in: root)
        try Data("user data".utf8).write(to: unknown.appendingPathComponent("keep.txt"))
        let future = try orphan(in: root)
        try Data("AWSPlatform upload snapshot v2\n".utf8).write(to: future.appendingPathComponent(S3UploadLease.markerName))
        let invalidName = root.appendingPathComponent(S3UploadLease.prefix + "not-a-uuid")
        try FileManager.default.createDirectory(at: invalidName, withIntermediateDirectories: false)
        S3UploadLease.cleanupOrphansSynchronously(in: root)
        for directory in [legacy, unknown, future, invalidName] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path), directory.path)
        }
    }

    func testSymlinkedDirectoryContentAndMarkerNeverFollowTargets() throws {
        let root = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let target = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: target)
        let linkedDirectory = root.appendingPathComponent(S3UploadLease.prefix + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: outside)
        let linkedContent = try orphan(in: root)
        try FileManager.default.createSymbolicLink(at: linkedContent.appendingPathComponent("content"), withDestinationURL: target)
        let linkedMarker = try orphan(in: root)
        let marker = linkedMarker.appendingPathComponent(S3UploadLease.markerName)
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)
        S3UploadLease.cleanupOrphansSynchronously(in: root)
        XCTAssertEqual(try String(contentsOf: target), "keep")
        for url in [linkedDirectory, linkedContent, linkedMarker] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testHardLinksNonPrivatePermissionsAndForeignOwnerAreNotEligible() throws {
        let root = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let linked = try orphan(in: root)
        let target = root.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: target)
        XCTAssertEqual(link(target.path, linked.appendingPathComponent("content").path), 0)
        let shared = try orphan(in: root)
        XCTAssertEqual(chmod(shared.path, 0o755), 0)
        S3UploadLease.cleanupOrphansSynchronously(in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        XCTAssertEqual(try String(contentsOf: target), "keep")
        var info = stat()
        info.st_uid = getuid() == 0 ? 1 : 0
        info.st_mode = S_IFREG | 0o600
        info.st_nlink = 1
        XCTAssertFalse(S3UploadLease.ownedPrivate(info, kind: S_IFREG, permissions: [0o600]))
        info.st_uid = getuid()
        XCTAssertTrue(S3UploadLease.ownedPrivate(info, kind: S_IFREG, permissions: [0o600]))
    }

    func testParentPathReplacementCannotRedirectLeaseCleanup() throws {
        let root = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected")
        let moved = root.appendingPathComponent("moved")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        var lease: S3UploadLease? = try S3UploadLease(root: selected)
        let name = try XCTUnwrap(lease).directory.lastPathComponent
        close(try XCTUnwrap(lease).createContent())
        try FileManager.default.moveItem(at: selected, to: moved)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: outside)
        let replacement = outside.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: replacement.appendingPathComponent("content"))
        lease = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent(name).path))
        XCTAssertEqual(try String(contentsOf: replacement.appendingPathComponent("content")), "keep")
    }

    func testContentCreationFailureStillRemovesOwnedSnapshotOnRelease() throws {
        let root = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var lease: S3UploadLease? = try S3UploadLease(root: root)
        let directory = try XCTUnwrap(lease).directory
        close(try XCTUnwrap(lease).createContent())
        XCTAssertThrowsError(try XCTUnwrap(lease).createContent())
        lease = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testContentReplacedAfterInspectionIsRestoredWithoutDeletingOrdinaryFileOrHardLink() throws {
        for hardLink in [false, true] {
            let root = try S3TransferFixtures.directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = try orphan(in: root)
            let content = directory.appendingPathComponent("content")
            let saved = root.appendingPathComponent("original-snapshot")
            let replacement = root.appendingPathComponent("user-file")
            try Data("snapshot".utf8).write(to: content)
            try Data("user data".utf8).write(to: replacement)
            XCTAssertEqual(chmod(content.path, 0o600), 0)
            XCTAssertEqual(chmod(replacement.path, 0o600), 0)
            var replaced = false
            S3UploadLease.cleanupOrphansSynchronously(in: root, beforeContentIsolation: {
                do {
                    try FileManager.default.moveItem(at: content, to: saved)
                    if hardLink {
                        XCTAssertEqual(link(replacement.path, content.path), 0)
                    } else {
                        try Data("replacement".utf8).write(to: content)
                        XCTAssertEqual(chmod(content.path, 0o600), 0)
                    }
                    replaced = true
                } catch { XCTFail("Unable to install controlled replacement: \(error)") }
            })
            XCTAssertTrue(replaced)
            XCTAssertEqual(try String(contentsOf: saved), "snapshot")
            XCTAssertEqual(try String(contentsOf: replacement), "user data")
            XCTAssertEqual(try String(contentsOf: content), hardLink ? "user data" : "replacement")
            let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertTrue(entries.contains(S3UploadLease.markerName))
            XCTAssertTrue(entries.contains("content"))
            XCTAssertEqual(entries.filter { $0.hasPrefix(".cleanup-") }.count, 1)
            S3UploadLease.cleanupOrphansSynchronously(in: root)
            XCTAssertEqual(try String(contentsOf: content), hardLink ? "user data" : "replacement")
        }
    }

    func testHardLinkAddedAfterInspectionMakesOriginalSnapshotIneligibleForDeletion() throws {
        let root = try S3TransferFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try orphan(in: root)
        let content = directory.appendingPathComponent("content")
        let linked = root.appendingPathComponent("new-user-link")
        try Data("now shared".utf8).write(to: content)
        XCTAssertEqual(chmod(content.path, 0o600), 0)
        S3UploadLease.cleanupOrphansSynchronously(in: root, beforeContentIsolation: {
            XCTAssertEqual(link(content.path, linked.path), 0)
        })
        XCTAssertEqual(try String(contentsOf: content), "now shared")
        XCTAssertEqual(try String(contentsOf: linked), "now shared")
        S3UploadLease.cleanupOrphansSynchronously(in: root)
        XCTAssertEqual(try String(contentsOf: content), "now shared")
    }

    private func orphan(in root: URL) throws -> URL {
        let directory = root.appendingPathComponent(S3UploadLease.prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let marker = directory.appendingPathComponent(S3UploadLease.markerName)
        try S3UploadLease.marker.write(to: marker)
        XCTAssertEqual(chmod(marker.path, 0o600), 0)
        return directory
    }
}
