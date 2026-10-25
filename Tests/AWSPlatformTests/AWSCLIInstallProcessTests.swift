import Foundation
import XCTest
@testable import AWSPlatform

final class AWSCLIInstallProcessTests: XCTestCase {
    func testOutputIsBoundedButLargeOutputDoesNotAbortInstallation() async throws {
        let command = fixture("/usr/bin/head -c 1048576 /dev/zero; printf stderr >&2; exit 0")
        let result = try await AWSCLIInstallProcess.run(command, outputLimit: 1024)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 1024)
        XCTAssertTrue(result.outputWasTruncated)
    }

    func testBothOutputStreamsAreCapturedAndNonzeroResultIsReturned() async throws {
        let result = try await AWSCLIInstallProcess.run(fixture("printf fixture; printf failure >&2; exit 8"))
        XCTAssertEqual(result.status, 8)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "fixturefailure")
        XCTAssertFalse(result.outputWasTruncated)
    }

    func testCallerCancellationWaitsForStartedProcessCompletion() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = root.appendingPathComponent("started")
        let finished = root.appendingPathComponent("finished")
        let command = AWSCLIInstallCommand(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf started > \"$1\"; /bin/sleep 0.3; printf finished > \"$2\"", "fixture", started.path, finished.path],
            environment: AWSCLIInstallProcess.environment(base: [:]))
        let task = Task { try await AWSCLIInstallProcess.run(command) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(try String(contentsOf: finished, encoding: .utf8), "finished")
    }

    func testLaunchFailureIsSanitized() async {
        let command = AWSCLIInstallCommand(executable: URL(fileURLWithPath: "/nonexistent/private-installer"), arguments: [], environment: [:])
        do { _ = try await AWSCLIInstallProcess.run(command); XCTFail("Expected launch failure") }
        catch {
            XCTAssertEqual(error as? AWSCLIUpdateError, .updateFailed)
            XCTAssertFalse(error.localizedDescription.contains("private-installer"))
        }
    }

    func testInstallEnvironmentDoesNotForwardCredentialsOrExecutableOverrides() {
        let environment = AWSCLIInstallProcess.environment(homebrew: true, base: [
            "HOME": "/fixture/home", "USER": "fixture", "TMPDIR": "/fixture/tmp",
            "AWS_ACCESS_KEY_ID": "private", "AWS_SECRET_ACCESS_KEY": "private", "AWS_SESSION_TOKEN": "private",
            "AWS_CONFIG_FILE": "private", "GITHUB_TOKEN": "private", "NPM_TOKEN": "private",
            "DYLD_INSERT_LIBRARIES": "private", "BASH_ENV": "private", "PATH": "/untrusted/bin",
            "HOMEBREW_BREW_GIT_REMOTE": "private", "HOMEBREW_CURL_PATH": "private"
        ])
        XCTAssertEqual(environment["HOME"], "/fixture/home")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(environment["LC_ALL"], "C")
        XCTAssertEqual(environment["HOMEBREW_NO_ANALYTICS"], "1")
        XCTAssertFalse(environment.values.contains("private"))
        XCTAssertEqual(Set(environment.keys), ["HOME", "USER", "TMPDIR", "PATH", "LANG", "LC_ALL",
            "HOMEBREW_NO_ANALYTICS", "HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK", "HOMEBREW_NO_INSTALL_CLEANUP", "HOMEBREW_NO_AUTO_UPDATE"])
    }

    private func fixture(_ command: String) -> AWSCLIInstallCommand {
        AWSCLIInstallCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command],
            environment: AWSCLIInstallProcess.environment(base: [:]))
    }

    private func makeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/aws-cli-update/process-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
