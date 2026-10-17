import Foundation
import XCTest
@testable import AWSPlatform

@MainActor
final class EC2SSMConnectionTests: XCTestCase {
    func testRequestRejectsMissingUnverifiedOrMalformedScopeAndInstance() throws {
        XCTAssertThrowsError(try EC2SSMConnectionRequest(scope: nil, instance: instance()))
        for value in ["", " ", "prod\nother", "prod\u{0}"] {
            XCTAssertThrowsError(try request(profile: value))
        }
        for id in ["i-example", "i-01234567\n", "i-01234567;id", "vol-01234567", "i-0123456789abcdef00"] {
            XCTAssertThrowsError(try EC2SSMConnectionRequest(scope: scope(), instance: instance(id: id)))
        }
        for region in ["", "us-east-1\n", "us-east-1;id"] {
            XCTAssertThrowsError(try EC2SSMConnectionRequest(scope: scope(region: region), instance: instance()))
        }
        XCTAssertThrowsError(try request(account: "not-an-account"))
        XCTAssertThrowsError(try request(config: "/tmp/config\nother"))
        XCTAssertThrowsError(try EC2SSMConnectionRequest(scope: scope(region: "us-west-2"), instance: instance()))
        for state in ["stopped", "pending", "terminated", "unknown", ""] {
            XCTAssertThrowsError(try EC2SSMConnectionRequest(scope: scope(), instance: instance(state: state))) {
                XCTAssertEqual($0 as? EC2SSMConnectionError, .notRunning)
            }
        }
        XCTAssertEqual(try request().instanceID, "i-0123456789abcdef0")
        XCTAssertNoThrow(try EC2SSMConnectionRequest(scope: scope(), instance: instance(id: "i-01234567")))
    }

    func testMissingDependenciesDoNotPrepareOrOpenAnything() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var service = EC2SSMConnectionService(cli: { nil }, plugin: { nil }, open: { _ in
            XCTFail("Must not open a terminal"); return false
        }, temporaryDirectory: root)
        XCTAssertThrowsError(try service.connect(request(), locale: .init(identifier: "en"))) {
            XCTAssertEqual($0 as? EC2SSMConnectionError, .cliMissing)
        }
        service.cli = { URL(fileURLWithPath: "/tmp/offline-aws") }
        XCTAssertThrowsError(try service.connect(request(), locale: .init(identifier: "en"))) {
            XCTAssertEqual($0 as? EC2SSMConnectionError, .pluginMissing)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testSystemHandoffReceivesPrivateExecutableCommandWithoutCredentials() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var opened: URL?
        let service = EC2SSMConnectionService(cli: { URL(fileURLWithPath: "/tmp/offline-aws") },
            plugin: { URL(fileURLWithPath: "/tmp/offline-plugin") }, open: { url in opened = url; return true },
            temporaryDirectory: root)
        try service.connect(request(), locale: .init(identifier: "en"))
        let url = try XCTUnwrap(opened)
        XCTAssertEqual(url.pathExtension, "command")
        for path in [url, url.deletingLastPathComponent()] {
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        let script = try String(contentsOf: url)
        XCTAssertTrue(script.contains("ssm start-session --target 'i-0123456789abcdef0'"))
        XCTAssertFalse(script.contains("AWS_SECRET_ACCESS_KEY"))
        XCTAssertFalse(script.contains("export-credentials"))
        XCTAssertFalse(script.contains("osascript"))
    }

    func testRejectedOpenAndPreparationFailureAreSanitizedAndCleaned() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var service = EC2SSMConnectionService(cli: { URL(fileURLWithPath: "/tmp/offline-aws") },
            plugin: { URL(fileURLWithPath: "/tmp/offline-plugin") }, open: { _ in false }, temporaryDirectory: root)
        XCTAssertThrowsError(try service.connect(request(), locale: .init(identifier: "en"))) {
            XCTAssertEqual($0 as? EC2SSMConnectionError, .openFailed)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        service.temporaryDirectory = root.appendingPathComponent("missing/parent")
        XCTAssertThrowsError(try service.connect(request(), locale: .init(identifier: "en"))) {
            XCTAssertEqual($0 as? EC2SSMConnectionError, .prepareFailed)
        }
    }

    func testExecutedScriptQuotesArgumentsIsolatesEnvironmentAndAcceptsRenewedSession() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("injected")
        let profile = "ops ' ; $(touch \(marker.path)) `touch \(marker.path)`"
        let req = try request(profile: profile, config: root.appendingPathComponent("config ' $(false)").path)
        let run = try execute(root: root, request: req, identity: "111122223333\tarn:aws:sts::111122223333:assumed-role/Operator/renewed")
        XCTAssertEqual(run.status, 0, run.output)
        XCTAssertEqual(run.calls.filter { $0 == "__CALL__" }.count, 2)
        XCTAssertTrue(run.calls.contains(profile))
        XCTAssertTrue(run.calls.contains(req.scope.configPath))
        XCTAssertTrue(run.calls.contains(req.scope.credentialsPath))
        XCTAssertEqual(run.calls.filter { $0 == "us-east-1" }.count, 2)
        XCTAssertTrue(run.calls.contains(req.instanceID))
        XCTAssertEqual(run.calls.filter { $0 == "ambient=unset/unset/unset/unset/unset" }.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.script.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.script.deletingLastPathComponent().path))
    }

    func testWrongAccountRoleMalformedOrFailedIdentityNeverStartsSession() throws {
        for identity in [
            "999900001111\tarn:aws:sts::999900001111:assumed-role/Operator/session",
            "111122223333\tarn:aws:sts::111122223333:assumed-role/Other/session",
            "111122223333\tarn:aws:sts::111122223333:assumed-role/Operator/session\textra",
            "111122223333\tarn:aws:sts::111122223333:assumed-role/Operator/session\nother",
            "", "not-an-identity"
        ] {
            let root = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let run = try execute(root: root, request: request(), identity: identity)
            XCTAssertNotEqual(run.status, 0)
            XCTAssertFalse(run.calls.contains("start-session"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: run.script.path))
        }
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = try execute(root: root, request: request(), identity: "", stsExit: 37)
        XCTAssertEqual(run.status, 37)
        XCTAssertFalse(run.calls.contains("start-session"))
    }

    func testIAMUserIdentityAndSSMFailureKeepExitStatusAndCleanup() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let arn = "arn:aws:iam::111122223333:user/operator"
        let run = try execute(root: root, request: request(arn: arn), identity: "111122223333\t\(arn)", ssmExit: 19)
        XCTAssertEqual(run.status, 19)
        XCTAssertTrue(run.calls.contains("start-session"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.script.path))
    }

    func testAllConnectionMessagesAreLocalized() {
        let keys = EC2SSMConnectionError.allCases.map(\.rawValue) + ["Connect", "Unable to connect",
            "Open an SSM session in your default terminal",
            "CLI identity does not match the verified Profile. Reverify the Profile in AWSPlatform before connecting."]
        for key in keys {
            XCTAssertNotEqual(L10n.text(key, locale: .init(identifier: "zh-Hans")), key)
            XCTAssertEqual(L10n.text(key, locale: .init(identifier: "en")), key)
        }
    }

    private func makeDirectory() throws -> URL {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".tmp/ec2-ssm/tests")
        let root = base.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func execute(root: URL, request: EC2SSMConnectionRequest, identity: String,
                         stsExit: Int = 0, ssmExit: Int = 0) throws -> (status: Int32, output: String, calls: [String], script: URL) {
        let cli = root.appendingPathComponent("aws ' offline")
        let log = root.appendingPathComponent("arguments")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // This executable is the only CLI the generated script can call. It never
        // loads AWS configuration, credentials, plugins or network libraries.
        let stub = """
        #!/bin/bash
        printf '%s\\n' '__CALL__' "$@" "$AWS_CONFIG_FILE" "$AWS_SHARED_CREDENTIALS_FILE" >> \(quote(log.path))
        printf 'ambient=%s/%s/%s/%s/%s\\n' "${AWS_ACCESS_KEY_ID-unset}" "${AWS_SESSION_TOKEN-unset}" "${AWS_PROFILE-unset}" "${AWS_ENDPOINT_URL-unset}" "${AWS_ROLE_ARN-unset}" >> \(quote(log.path))
        if [[ "$1" == sts ]]; then
            printf '%s\\n' \(quote(identity))
            exit \(stsExit)
        fi
        exit \(ssmExit)
        """
        try Data(stub.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        var script: URL?
        let service = EC2SSMConnectionService(cli: { cli }, plugin: { cli },
            open: { script = $0; return true }, temporaryDirectory: root, homeDirectory: root)
        try service.connect(request, locale: .init(identifier: "en"))
        let url = try XCTUnwrap(script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", url.path]
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path,
            "AWS_ACCESS_KEY_ID": "offline-ambient", "AWS_SESSION_TOKEN": "offline-token",
            "AWS_PROFILE": "wrong-profile", "AWS_ENDPOINT_URL": "http://127.0.0.1:1", "AWS_ROLE_ARN": "wrong-role"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self),
                try String(contentsOf: log).components(separatedBy: "\n"), url)
    }

    private func request(profile: String = "production", account: String = "111122223333",
                         config: String = "/tmp/offline/config", arn: String = "arn:aws:sts::111122223333:assumed-role/Operator/session") throws -> EC2SSMConnectionRequest {
        try EC2SSMConnectionRequest(scope: scope(profile: profile, account: account, config: config, arn: arn), instance: instance())
    }

    private func scope(profile: String = "production", account: String = "111122223333", region: String = "us-east-1",
                       config: String = "/tmp/offline/config", arn: String = "arn:aws:sts::111122223333:assumed-role/Operator/session") -> MonitoringScope {
        MonitoringScope(profile: .init(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil,
            ssoAccountID: nil, ssoRoleName: nil), identity: .init(account: account, arn: arn, userID: "offline"), region: region,
            paths: .init(environment: ["AWS_CONFIG_FILE": config, "AWS_SHARED_CREDENTIALS_FILE": "/tmp/offline/credentials ' $(false)"]))
    }

    private func instance(id: String = "i-0123456789abcdef0", state: String = "running") -> EC2InstanceModel {
        .init(instanceId: id, name: "Offline instance", instanceType: "t3.micro", state: state,
              privateIP: nil, publicIP: nil, platformDetails: nil, architecture: nil, vpcId: nil,
              subnetId: nil, availabilityZone: "us-east-1a", securityGroups: [], imageId: nil, imageName: nil,
              keyName: nil, launchTime: nil, tags: [:])
    }
}
