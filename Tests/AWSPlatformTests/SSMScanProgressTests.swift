import Darwin
import Foundation
import XCTest
@testable import AWSPlatform

@MainActor
final class SSMScanProgressTests: XCTestCase {
    func testSmallScanBudgetResumesBeyondUnrelatedEntries() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/ssm-script-cleanup/scan-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<32 { try Data("keep".utf8).write(to: root.appendingPathComponent("000-unrelated-\(index)")) }
        var pending: URL?
        for _ in 0..<32 {
            let lease = try SSMScriptLease(root: root)
            try lease.writeScript("#!/bin/bash\nexit 0\n")
            try lease.releaseForHandoff()
            if try firstEntry(in: root).hasPrefix("000-unrelated-") { pending = lease.directory; break }
            lease.discard()
        }
        let scriptDirectory = try XCTUnwrap(pending)
        let now = Date().addingTimeInterval(48 * 60 * 60)
        XCTAssertTrue(SSMScriptLease.cleanupOrphansSynchronously(in: root, now: now, entryLimit: 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scriptDirectory.path))
        for _ in 0..<40 {
            _ = SSMScriptLease.cleanupOrphansSynchronously(in: root, now: now, entryLimit: 1)
            if !FileManager.default.fileExists(atPath: scriptDirectory.path) { break }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptDirectory.path))
        for index in 0..<32 { XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("000-unrelated-\(index)")), "keep") }
    }

    func testOneAsyncCleanupAdvancesAcrossSeveralSmallBatches() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/ssm-script-cleanup/async-scan-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<8 { try Data("keep".utf8).write(to: root.appendingPathComponent("000-unrelated-\(index)")) }
        var pending: URL?
        for _ in 0..<32 {
            let lease = try SSMScriptLease(root: root)
            try lease.writeScript("#!/bin/bash\nexit 0\n")
            try lease.releaseForHandoff()
            if try firstEntry(in: root).hasPrefix("000-unrelated-") { pending = lease.directory; break }
            lease.discard()
        }
        let scriptDirectory = try XCTUnwrap(pending)
        await SSMScriptLease.cleanupOrphans(in: root, now: Date().addingTimeInterval(48 * 60 * 60),
                                          entryLimit: 1, maximumBatches: 16)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptDirectory.path))
        for index in 0..<8 { XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("000-unrelated-\(index)")), "keep") }
    }

    private func firstEntry(in root: URL) throws -> String {
        let stream = try XCTUnwrap(opendir(root.path))
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { return name }
        }
        throw CocoaError(.fileReadUnknown)
    }
}
