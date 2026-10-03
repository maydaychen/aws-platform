import Darwin
import XCTest
@testable import AWSPlatform

@MainActor
final class AWSSSOLoginServiceTests: XCTestCase {
    func testLoginPassesLiteralSessionWithoutProfileAndMatchingConfigurationPaths() async throws {
        let paths = AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": "/example/config", "AWS_SHARED_CREDENTIALS_FILE": "/example/credentials"
        ])
        let service = AWSSSOLoginService { arguments, environment in
            XCTAssertEqual(arguments, ["sso", "login", "--sso-session", "work; $(echo unsafe)", "--no-cli-pager", "--no-cli-auto-prompt"])
            XCTAssertEqual(environment["AWS_CONFIG_FILE"], paths.config)
            XCTAssertEqual(environment["AWS_SHARED_CREDENTIALS_FILE"], paths.credentials)
            XCTAssertEqual(environment["AWS_CLI_AUTO_PROMPT"], "off")
            XCTAssertEqual(environment["AWS_PAGER"], "")
            XCTAssertEqual(environment["AWS_CLI_HISTORY_FILE"], "/dev/null")
            XCTAssertNil(environment["AWS_PROFILE"])
            XCTAssertNil(environment["AWS_DEFAULT_PROFILE"])
        }
        try await service.login(session: "work; $(echo unsafe)", paths: paths)
    }

    func testEnvironmentRemovesAmbientCredentialsAndPreservesProxy() {
        let keys = ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
                    "AWS_SECURITY_TOKEN", "AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_ROLE_ARN"]
        var base = Dictionary(uniqueKeysWithValues: keys.map { ($0, "EXAMPLE") })
        base["HTTPS_PROXY"] = "http://localhost:8080"
        let environment = AWSCLIConfiguration.environment(paths: AWSConfigurationPaths(), base: base)
        for key in keys { XCTAssertNil(environment[key]) }
        XCTAssertEqual(environment["HTTPS_PROXY"], base["HTTPS_PROXY"])
    }

    func testLoginChildIgnoresAmbientProfilesAndPreservesConfigurationPaths() async throws {
        let paths = AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": "/example/config with spaces",
            "AWS_SHARED_CREDENTIALS_FILE": "/example/credentials with spaces"
        ])
        let base = [
            "AWS_PROFILE": "missing-ambient-profile",
            "AWS_DEFAULT_PROFILE": "missing-default-profile",
            "EXPECTED_CONFIG_FILE": paths.config,
            "EXPECTED_CREDENTIALS_FILE": paths.credentials
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("aws")
        try """
        #!/bin/sh
        test "${AWS_PROFILE+x}" != x || exit 11
        test "${AWS_DEFAULT_PROFILE+x}" != x || exit 12
        test "$AWS_CONFIG_FILE" = "$EXPECTED_CONFIG_FILE" || exit 13
        test "$AWS_SHARED_CREDENTIALS_FILE" = "$EXPECTED_CREDENTIALS_FILE" || exit 14
        test "$1" = sso && test "$2" = login && test "$3" = --sso-session && test "$4" = company || exit 15
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try await AWSSSOLoginService.run(
            executable: executable,
            arguments: ["sso", "login", "--sso-session", "company"],
            environment: AWSSSOLoginService.loginEnvironment(paths: paths, base: base)
        )
        let providerEnvironment = AWSCLIConfiguration.environment(paths: paths, base: base)
        XCTAssertEqual(providerEnvironment["AWS_PROFILE"], base["AWS_PROFILE"])
        XCTAssertEqual(providerEnvironment["AWS_DEFAULT_PROFILE"], base["AWS_DEFAULT_PROFILE"])
    }

    func testMissingCLIAndEmptySessionHaveActionableErrors() async {
        XCTAssertNil(AWSCLIConfiguration.executable(candidates: ["/nonexistent/aws-platform-test/aws"]))
        XCTAssertTrue(AWSSSOLoginService.LoginError.cliMissing.localizedDescription.contains("AWS CLI v2"))
        let service = AWSSSOLoginService { _, _ in XCTFail("Empty session must not launch") }
        do {
            try await service.login(session: "  \n", paths: AWSConfigurationPaths())
            XCTFail("Expected invalid session")
        } catch {
            XCTAssertEqual(error as? AWSSSOLoginService.LoginError, .invalidSession)
        }
    }

    func testRunnerFailureDoesNotExposePrivateOutput() async {
        let service = AWSSSOLoginService { _, _ in
            throw NSError(domain: "private-authorization-url", code: 1)
        }
        do {
            try await service.login(session: "work", paths: AWSConfigurationPaths())
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? AWSSSOLoginService.LoginError, .failed)
            XCTAssertFalse(error.localizedDescription.contains("private-authorization-url"))
        }
    }

    func testProcessSuccessAndNonzeroExit() async throws {
        try await AWSSSOLoginService.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], environment: [:])
        do {
            try await AWSSSOLoginService.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], environment: [:])
            XCTFail("Expected nonzero exit failure")
        } catch {
            XCTAssertEqual(error as? AWSSSOLoginService.LoginError, .failed)
        }
    }

    func testLaunchFailureIsSanitized() async {
        do {
            try await AWSSSOLoginService.run(executable: URL(fileURLWithPath: "/nonexistent/aws"), arguments: [], environment: [:])
            XCTFail("Expected launch failure")
        } catch {
            XCTAssertEqual(error as? AWSSSOLoginService.LoginError, .launchFailed)
        }
    }

    func testTimeoutTerminatesChild() async throws {
        try await assertChildStops(cancel: false)
    }

    func testCancellationTerminatesChild() async throws {
        try await assertChildStops(cancel: true)
    }

    func testTimeoutStopsChildThatIgnoresTerminateSignal() async throws {
        try await assertChildStops(cancel: false, ignoresTerminate: true)
    }

    func testAlreadyCancelledTaskDoesNotLaunchProcess() async {
        let task = Task {
            try await AWSSSOLoginService.run(executable: URL(fileURLWithPath: "/nonexistent/aws"), arguments: [], environment: [:])
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testAlreadyCancelledLoginDoesNotInvokeRunner() async {
        let service = AWSSSOLoginService { _, _ in XCTFail("Cancelled login must not launch") }
        let task = Task {
            try await service.login(session: "company", paths: AWSConfigurationPaths())
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func assertChildStops(cancel: Bool, ignoresTerminate: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let task = Task {
            try await AWSSSOLoginService.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", (ignoresTerminate ? "trap '' TERM; " : "") + "echo $$ > \"$1\"; exec /bin/sleep 30", "test", pidFile.path],
                environment: [:], timeout: cancel ? .seconds(5) : .seconds(1)
            )
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        if cancel { task.cancel() }
        do {
            try await task.value
            XCTFail("Expected cancellation or timeout")
        } catch {
            if cancel { XCTAssertTrue(error is CancellationError) }
            else { XCTAssertEqual(error as? AWSSSOLoginService.LoginError, .timedOut) }
        }
        XCTAssertEqual(kill(pid, 0), -1, "Login child must be gone before returning")
        XCTAssertEqual(errno, ESRCH)
    }
}
