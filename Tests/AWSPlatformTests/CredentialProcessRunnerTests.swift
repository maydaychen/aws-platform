import Darwin
import Foundation
import XCTest
@testable import AWSPlatform

final class CredentialProcessRunnerTests: XCTestCase {
    func testSuccessfulProcessReturnsItsMemoryOutput() async throws {
        let result = try await run("printf 'fixture-output'")
        XCTAssertEqual(result, Data("fixture-output".utf8))
    }

    func testNonzeroExitAndLaunchFailureAreSanitized() async {
        do {
            _ = try await run("printf 'private-output'; printf 'private-error' >&2; exit 7")
            XCTFail("Expected process failure")
        } catch {
            XCTAssertEqual(error as? CredentialProcessRunner.Failure, .unavailable)
            XCTAssertFalse(error.localizedDescription.contains("private-output"))
            XCTAssertFalse(error.localizedDescription.contains("private-error"))
        }
        do {
            _ = try await CredentialProcessRunner.run(
                executable: URL(fileURLWithPath: "/nonexistent/credential-tool"), arguments: [], environment: [:]
            )
            XCTFail("Expected launch failure")
        } catch {
            XCTAssertEqual(error as? CredentialProcessRunner.Failure, .unavailable)
            XCTAssertFalse(error.localizedDescription.contains("credential-tool"))
        }
    }

    func testTimeoutKillsAndReapsChildIgnoringTerminate() async throws {
        try await assertIgnoringTerminateStops(cancel: false)
    }

    func testCancellationKillsAndReapsChildIgnoringTerminate() async throws {
        try await assertIgnoringTerminateStops(cancel: true)
    }

    func testTimeoutDoesNotWaitForGrandchildHoldingOutputOpen() async throws {
        try await assertInheritedWriterIsBounded(cancel: false)
    }

    func testCancellationDoesNotWaitForGrandchildHoldingOutputOpen() async throws {
        try await assertInheritedWriterIsBounded(cancel: true)
    }

    func testOutputLimitStopsTheChildWithoutReturningPartialOutput() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await run("exec /usr/bin/head -c 1048576 /dev/zero", outputLimit: 1024)
            XCTFail("Expected output limit failure")
        } catch {
            XCTAssertEqual(error as? CredentialProcessRunner.Failure, .outputLimit)
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testAlreadyCancelledTaskDoesNotStartChild() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let gate = TestGate()
        let task = Task {
            await gate.wait()
            return try await CredentialProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo started > \"$1\"", "fixture", marker.path], environment: [:]
            )
        }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testClosedOutputDoesNotBypassChildExitTimeout() async throws {
        let start = ContinuousClock.now
        do {
            _ = try await run("exec 1>&-; exec /bin/sleep 3", timeout: .milliseconds(100))
            XCTFail("Expected timeout while child remains alive")
        } catch {
            XCTAssertEqual(error as? CredentialProcessRunner.Failure, .timedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    private func assertIgnoringTerminateStops(cancel: Bool) async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let task = Task {
            try await CredentialProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; echo $$ > \"$1\"; exec /bin/sleep 3", "fixture", pidFile.path],
                environment: [:], timeout: cancel ? .seconds(5) : .milliseconds(200),
                terminationGrace: .milliseconds(100)
            )
        }
        defer { task.cancel() }
        let pid = try await Self.waitForPID(at: pidFile)
        let start = ContinuousClock.now
        if cancel { task.cancel() }
        do { _ = try await task.value; XCTFail("Expected cancellation or timeout") }
        catch {
            if cancel { XCTAssertTrue(error is CancellationError) }
            else { XCTAssertEqual(error as? CredentialProcessRunner.Failure, .timedOut) }
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertEqual(kill(pid, 0), -1, "The direct child must be reaped before returning")
        XCTAssertEqual(errno, ESRCH)
    }

    private func assertInheritedWriterIsBounded(cancel: Bool) async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("descendant-pid")
        let task = Task {
            try await CredentialProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "/bin/sleep 3 & echo $! > \"$1\"; exit 0", "fixture", pidFile.path],
                environment: [:], timeout: cancel ? .seconds(5) : .milliseconds(200),
                terminationGrace: .milliseconds(100)
            )
        }
        defer { task.cancel() }
        let descendant = try await Self.waitForPID(at: pidFile)
        // Only this fixture's explicitly recorded descendant is cleaned up here.
        defer { kill(descendant, SIGKILL) }
        let start = ContinuousClock.now
        if cancel { task.cancel() }
        do { _ = try await task.value; XCTFail("Expected cancellation or timeout") }
        catch {
            if cancel { XCTAssertTrue(error is CancellationError) }
            else { XCTAssertEqual(error as? CredentialProcessRunner.Failure, .timedOut) }
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertEqual(kill(descendant, 0), 0, "The runner must not signal unrelated descendants")
    }

    private func run(
        _ command: String, timeout: Duration = .seconds(3), outputLimit: Int = 64 * 1024
    ) async throws -> Data {
        try await CredentialProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command], environment: [:],
            timeout: timeout, terminationGrace: .milliseconds(100), outputLimit: outputLimit
        )
    }

    private static func makeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/audit-fixes/f3/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func waitForPID(at file: URL) async throws -> pid_t {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if let contents = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "CredentialProcessFixtureDidNotStart", code: 1)
    }
}
