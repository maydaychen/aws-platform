import Darwin
import Foundation
import XCTest
@testable import AWSPlatform

final class SSMDirectoryCleanupTests: XCTestCase {
    func testCleanupOnlyScansPrivateParentAndRemovesAllExpiredHandoffs() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<32 { try Data("keep".utf8).write(to: root.appendingPathComponent("unrelated-\(index)")) }
        let legacy = root.appendingPathComponent(SSMScriptLease.prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        var handoffs: [URL] = []
        for _ in 0..<3 {
            let lease = try SSMScriptLease(root: root)
            try lease.writeScript("#!/bin/bash\nexit 0\n")
            try lease.releaseForHandoff()
            handoffs.append(lease.directory)
        }
        await SSMScriptLease.cleanupOrphans(in: root, now: Date().addingTimeInterval(48 * 60 * 60))
        for handoff in handoffs { XCTAssertFalse(FileManager.default.fileExists(atPath: handoff.path)) }
        for index in 0..<32 { XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("unrelated-\(index)")), "keep") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testSymlinkedOrNonPrivateParentIsRejected() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let keep = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: keep)
        let parent = root.appendingPathComponent(SSMScriptLease.parentDirectoryName)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        XCTAssertThrowsError(try SSMScriptLease(root: root))
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: Date().addingTimeInterval(48 * 60 * 60))
        XCTAssertEqual(try String(contentsOf: keep), "keep")
        try FileManager.default.removeItem(at: parent)
        let lease = try SSMScriptLease(root: root)
        try lease.writeScript("#!/bin/bash\nexit 0\n")
        try lease.releaseForHandoff()
        XCTAssertEqual(chmod(parent.path, 0o755), 0)
        XCTAssertThrowsError(try SSMScriptLease(root: root))
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: Date().addingTimeInterval(48 * 60 * 60))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.scriptURL.path))
    }

    func testCleanupDoesNotCreateMissingParent() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        SSMScriptLease.cleanupOrphansSynchronously(in: root)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/ssm-simplification/directories/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
