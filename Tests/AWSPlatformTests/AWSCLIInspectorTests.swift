import Foundation
import XCTest
@testable import AWSPlatform

final class AWSCLIInspectorTests: XCTestCase {
    func testMissingExecutableDoesNotLaunchAnyProcess() async throws {
        let calls = InspectorCalls()
        let inspector = AWSCLIInspector(candidates: ["/nonexistent/aws-cli-test"], runner: { _, _, _ in
            await calls.record()
            return Data()
        })
        let result = try await inspector.inspect()
        let count = await calls.count
        XCTAssertNil(result)
        XCTAssertEqual(count, 0)
    }

    func testEffectiveCandidatePriorityAndCustomSourceRemainUnmanaged() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try makeExecutable(directory, name: "first")
        let second = try makeExecutable(directory, name: "second")
        let calls = InspectorCalls()
        let inspector = AWSCLIInspector(candidates: [first.path, second.path], runner: { executable, args, environment in
            await calls.record(executable: executable, arguments: args, environment: environment)
            return Data("aws-cli/2.38.5 Python/3.13".utf8)
        }, officialVerifier: { _, _ in true }, homebrewVerifier: { _, _ in true })
        let detected = try await inspector.inspect()
        let result = try XCTUnwrap(detected)
        XCTAssertEqual(result.executableURL, first)
        XCTAssertEqual(result.source, .unmanaged)
        let snapshot = await calls.snapshot()
        XCTAssertEqual(snapshot.0, first)
        XCTAssertEqual(snapshot.1, ["--version"])
        XCTAssertFalse(snapshot.2.keys.contains(where: { $0.contains("TOKEN") || $0.contains("SECRET") || $0 == "AWS_PROFILE" }))
        XCTAssertEqual(snapshot.2["AWS_CONFIG_FILE"], "/dev/null")
        XCTAssertEqual(snapshot.2["AWS_SHARED_CREDENTIALS_FILE"], "/dev/null")
    }

    func testVersionOneIsVisibleButNeverEligibleForAutomaticUpdate() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeExecutable(directory, name: "aws")
        let inspector = AWSCLIInspector(candidates: [file.path], runner: { _, _, _ in
            Data("aws-cli/1.40.0 Python/3.10".utf8)
        })
        let detected = try await inspector.inspect()
        let result = try XCTUnwrap(detected)
        XCTAssertEqual(result.version, AWSCLIVersion("1.40.0"))
        XCTAssertEqual(result.source, .unmanaged)
    }

    func testMalformedOutputAndProcessFailureRemainSanitized() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try makeExecutable(directory, name: "aws")
        for output in [Data("private-output".utf8), Data([0xff])] {
            let inspector = AWSCLIInspector(candidates: [file.path], runner: { _, _, _ in output })
            do { _ = try await inspector.inspect(); XCTFail("Expected invalid version") }
            catch { XCTAssertEqual(error as? AWSCLIUpdateError, .invalidVersion) }
        }
        let inspector = AWSCLIInspector(candidates: [file.path], runner: { _, _, _ in
            throw NSError(domain: "private-credential", code: 1)
        })
        do { _ = try await inspector.inspect(); XCTFail("Expected sanitized failure") }
        catch {
            XCTAssertEqual(error as? AWSCLIUpdateError, .checkFailed)
            XCTAssertFalse(error.localizedDescription.contains("private-credential"))
        }
    }

    func testEnvironmentDoesNotInheritCredentialsConfigOrExecutableOverrides() {
        let environment = AWSCLIInspector.processEnvironment(base: [
            "HOME": "/fixture", "USER": "fixture", "AWS_ACCESS_KEY_ID": "private",
            "AWS_SESSION_TOKEN": "private", "AWS_PROFILE": "private", "AWS_CONFIG_FILE": "/private",
            "PYTHONPATH": "/private", "DYLD_INSERT_LIBRARIES": "/private", "PATH": "/private"
        ])
        XCTAssertEqual(environment["HOME"], "/fixture")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertFalse(environment.values.contains("private"))
        XCTAssertEqual(environment["AWS_CONFIG_FILE"], "/dev/null")
        XCTAssertEqual(environment["AWS_SHARED_CREDENTIALS_FILE"], "/dev/null")
        XCTAssertNil(environment["PYTHONPATH"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
    }

    func testSourcePathsMustMatchCanonicalPackageOrMatchingBrewKegVersion() throws {
        let version = try XCTUnwrap(AWSCLIVersion("2.38.5"))
        XCTAssertTrue(AWSCLIInspector.isOfficialPath(URL(fileURLWithPath: "/usr/local/aws-cli/aws"), version: version))
        XCTAssertTrue(AWSCLIInspector.isOfficialPath(URL(fileURLWithPath: "/usr/local/aws-cli/v2/2.38.5/bin/aws"), version: version))
        XCTAssertFalse(AWSCLIInspector.isOfficialPath(URL(fileURLWithPath: "/usr/local/aws-cli-evil/aws"), version: version))
        XCTAssertFalse(AWSCLIInspector.isOfficialPath(URL(fileURLWithPath: "/usr/local/aws-cli/v2/2.38.4/bin/aws"), version: version))
        for prefix in ["/opt/homebrew", "/usr/local"] {
            XCTAssertEqual(AWSCLIInspector.homebrewPrefix(for: URL(fileURLWithPath: "\(prefix)/Cellar/awscli/2.38.5/bin/aws"), version: version)?.path, prefix)
            XCTAssertNotNil(AWSCLIInspector.homebrewPrefix(for: URL(fileURLWithPath: "\(prefix)/Cellar/awscli/2.38.5_1/bin/aws"), version: version))
            XCTAssertEqual(AWSCLIInspector.homebrewPrefix(for: URL(fileURLWithPath: "\(prefix)/Cellar/awscli/2.38.5/libexec/bin/aws"), version: version)?.path, prefix)
        }
        for path in ["/tmp/Cellar/awscli/2.38.5/bin/aws", "/opt/homebrew/Cellar/other/2.38.5/bin/aws",
                     "/opt/homebrew/Cellar/awscli/2.38.4/bin/aws", "/opt/homebrew/Cellar/awscli/2.38.5_abc/bin/aws",
                     "/opt/homebrew/Cellar/awscli/2.38.5/bin/evil/aws"] {
            XCTAssertNil(AWSCLIInspector.homebrewPrefix(for: URL(fileURLWithPath: path), version: version))
        }
    }

    func testPackageReceiptMustMatchIdentifierVersionAndSystemInstallLocation() throws {
        let version = try XCTUnwrap(AWSCLIVersion("2.38.5"))
        let valid = ["pkgid": "com.amazon.aws.cli2", "pkg-version": "2.38.5", "volume": "/", "install-location": "usr/local"]
        func data(_ value: [String: String]) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        }
        XCTAssertTrue(AWSCLIInspector.officialReceiptMatches(try data(valid), version: version))
        for (key, value) in [("pkgid", "com.other.cli"), ("pkg-version", "2.38.4"),
                             ("volume", "/external"), ("install-location", "Users/fixture")] {
            var invalid = valid
            invalid[key] = value
            XCTAssertFalse(AWSCLIInspector.officialReceiptMatches(try data(invalid), version: version))
        }
        XCTAssertFalse(AWSCLIInspector.officialReceiptMatches(Data("invalid".utf8), version: version))
    }

    func testHomebrewReceiptMustContainBrewProvenanceAndMatchingStableVersion() throws {
        let version = try XCTUnwrap(AWSCLIVersion("2.38.5"))
        let valid = Data(#"{"homebrew_version":"4.6.0","source":{"versions":{"stable":"2.38.5"}}}"#.utf8)
        XCTAssertTrue(AWSCLIInspector.homebrewReceiptMatches(valid, version: version))
        for invalid in [#"{"source":{"versions":{"stable":"2.38.5"}}}"#,
                        #"{"homebrew_version":"4.6.0","source":{"versions":{"stable":"2.38.4"}}}"#,
                        #"{"homebrew_version":"4.6.0","source":{}}"#] {
            XCTAssertFalse(AWSCLIInspector.homebrewReceiptMatches(Data(invalid.utf8), version: version))
        }
    }

    private func makeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/aws-cli-update/inspector/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExecutable(_ directory: URL, name: String) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}

private actor InspectorCalls {
    var count = 0
    var executable: URL?
    var arguments: [String] = []
    var environment: [String: String] = [:]
    func record(executable: URL? = nil, arguments: [String] = [], environment: [String: String] = [:]) {
        count += 1
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
    func snapshot() -> (URL?, [String], [String: String]) { (executable, arguments, environment) }
}
