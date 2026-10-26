import Darwin
import Foundation
import XCTest
@testable import AWSPlatform

@MainActor
final class SSMHandoffCleanupTests: XCTestCase {
    func testSuccessfulOpenWithoutExecutionIsRetainedOnlyUntilExpiry() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try prepare(in: root)
        let marker = script.deletingLastPathComponent().appendingPathComponent(SSMScriptLease.markerName)
        let values = try FileManager.default.attributesOfItem(atPath: marker.path)
        let created = try XCTUnwrap(values[.modificationDate] as? Date)
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: created.addingTimeInterval(SSMScriptLease.maximumPendingAge - 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: created.addingTimeInterval(SSMScriptLease.maximumPendingAge))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.deletingLastPathComponent().path))
    }

    func testDirectorySymlinkReplacementCannotDeleteExternalFilesOrReachCLI() throws {
        for locked in [false, true] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let script = try prepare(in: root)
            let body = try String(contentsOf: script)
            let pending = script.deletingLastPathComponent()
            let moved = root.appendingPathComponent("original-pending")
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: pending, to: moved)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let externalScript = outside.appendingPathComponent(SSMScriptLease.scriptName)
            let externalMarker = outside.appendingPathComponent(SSMScriptLease.markerName)
            try Data("keep script".utf8).write(to: externalScript)
            try Data("keep marker".utf8).write(to: externalMarker)
            try FileManager.default.createSymbolicLink(at: pending, withDestinationURL: outside)
            // An associated app already has the generated body; its named directory is replaced before cleanup.
            let result = try execute(body: body, script: script, arguments: locked ? ["--awsplatform-ssm-locked"] : [])
            XCTAssertNotEqual(result.status, 0)
            XCTAssertEqual(try String(contentsOf: externalScript), "keep script")
            XCTAssertEqual(try String(contentsOf: externalMarker), "keep marker")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("calls")), "")
        }
    }

    func testRealScriptUnlinksBeforeFirstCLIAndPreservesSuccessfulOrFailedExit() throws {
        for code in [0, 37] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let script = try prepare(in: root)
            try writeCLIFixtures(in: root, script: script, exit: code)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["--noprofile", "--norc", script.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, Int32(code))
            XCTAssertFalse(FileManager.default.fileExists(atPath: script.deletingLastPathComponent().path))
            XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("calls")).contains("ssm"))
        }
    }

    func testIncompleteDirectoryCleanupDoesNotBlockSessionOrMaskItsExitStatus() throws {
        for code in [0, 37] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let script = try prepare(in: root)
            try writeCLIFixtures(in: root, script: script, exit: code)
            let keep = script.deletingLastPathComponent().appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: keep)
            let result = try execute(body: String(contentsOf: script), script: script, arguments: [])
            XCTAssertEqual(result.status, Int32(code), result.output)
            XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("calls")).contains("ssm"))
            XCTAssertEqual(try String(contentsOf: keep), "keep")
            XCTAssertTrue(result.output.contains("SSM temporary files could not be fully removed"))
        }
    }

    func testFileCleanupPermissionFailureWarnsAndStillStartsSession() throws {
        try XCTSkipIf(geteuid() == 0, "Root bypasses directory write permissions")
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try prepare(in: root)
        let pending = script.deletingLastPathComponent()
        defer { _ = chmod(pending.path, 0o700) }
        try writeCLIFixtures(in: root, script: script, exit: 0, requireRemovedFiles: false)
        XCTAssertEqual(chmod(pending.path, 0o500), 0)
        let result = try execute(body: String(contentsOf: script), script: script, arguments: [])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("calls")).contains("ssm"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.appendingPathComponent(SSMScriptLease.markerName).path))
        XCTAssertTrue(result.output.contains("SSM temporary files could not be fully removed"))
        XCTAssertFalse(result.output.contains("offline-secret"))
    }

    func testKillingLockfParentDoesNotStopAnAlreadyStartedSession() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = try prepare(in: root)
        try writeCLIFixtures(in: root, script: script, exit: 0)
        let started = root.appendingPathComponent("session-started")
        let release = root.appendingPathComponent("session-release")
        let finished = root.appendingPathComponent("session-finished")
        let cli = root.appendingPathComponent("aws")
        let body = try String(contentsOf: cli)
        XCTAssertTrue(body.contains("ssm) exit 0 ;;"))
        let session = """
        ssm)
            printf '%s\\n' "$$" > \(quote(started.path))
            while [[ ! -f \(quote(release.path)) && "$SECONDS" -lt 10 ]]; do /bin/sleep 0.02; done
            [[ -f \(quote(release.path)) ]] || exit 91
            printf '%s\\n' finished > \(quote(finished.path))
            exit 0 ;;
        """
        try Data(body.replacingOccurrences(of: "ssm) exit 0 ;;", with: session).utf8).write(to: cli)
        XCTAssertEqual(chmod(cli.path, 0o700), 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var child: pid_t?
        defer {
            try? Data().write(to: release)
            if !FileManager.default.fileExists(atPath: finished.path), let child { _ = kill(child, SIGTERM) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        }
        try process.run()
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if let value = try? String(contentsOf: started), value.hasSuffix("\n") {
                child = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines))
                if child != nil { break }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let liveChild = try XCTUnwrap(child)
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.deletingLastPathComponent().path))
        SSMScriptLease.cleanupOrphansSynchronously(in: root, now: Date().addingTimeInterval(48 * 60 * 60))
        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(kill(liveChild, 0), 0)
        try Data().write(to: release)
        let completed = Date().addingTimeInterval(4)
        while !FileManager.default.fileExists(atPath: finished.path), Date() < completed {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.deletingLastPathComponent().path))
    }

    private func prepare(in root: URL) throws -> URL {
        let cli = root.appendingPathComponent("aws")
        let plugin = root.appendingPathComponent("session-manager-plugin")
        let calls = root.appendingPathComponent("calls")
        try Data().write(to: calls)
        for executable in [cli, plugin] {
            try Data("#!/bin/bash\nprintf '%s\\n' reached >> \(quote(calls.path))\nexit 88\n".utf8).write(to: executable)
            XCTAssertEqual(chmod(executable.path, 0o700), 0)
        }
        let scope = MonitoringScope(profile: .init(name: "offline", region: "us-east-1", ssoStartURL: nil,
            ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
            identity: .init(account: "111122223333", arn: "arn:aws:sts::111122223333:assumed-role/Operator/old", userID: "offline"),
            region: "us-east-1", paths: .init(environment: ["AWS_CONFIG_FILE": root.appendingPathComponent("config").path,
                "AWS_SHARED_CREDENTIALS_FILE": root.appendingPathComponent("credentials").path]))
        let instance = EC2InstanceModel(instanceId: "i-0123456789abcdef0", name: "Offline", instanceType: "t3.micro",
            state: "running", privateIP: nil, publicIP: nil, platformDetails: nil, architecture: nil, vpcId: nil,
            subnetId: nil, availabilityZone: "us-east-1a", securityGroups: [], imageId: nil, imageName: nil,
            keyName: nil, launchTime: nil, tags: [:])
        var opened: URL?
        let service = EC2SSMConnectionService(cli: { cli }, plugin: { plugin }, open: { opened = $0; return true },
                                             temporaryDirectory: root, homeDirectory: root)
        try service.connect(.init(scope: scope, instance: instance), locale: .init(identifier: "en"))
        return try XCTUnwrap(opened)
    }

    private func writeCLIFixtures(in root: URL, script: URL, exit code: Int, requireRemovedFiles: Bool = true) throws {
        let marker = script.deletingLastPathComponent().appendingPathComponent(SSMScriptLease.markerName)
        let guardLine = requireRemovedFiles
            ? "[[ ! -e \(quote(script.path)) && ! -e \(quote(marker.path)) && -d \"$PWD\" ]] || exit 89"
            : "[[ -d \"$PWD\" ]] || exit 89"
        let cli = """
        #!/bin/bash
        set -euo pipefail
        \(guardLine)
        printf '%s\\n' "$1" >> \(quote(root.appendingPathComponent("calls").path))
        case "$1" in
            --version) printf '%s\\n' 'aws-cli/2.37.9 Python/offline' ;;
            configure) printf '%s\\n' '{"Version":1,"AccessKeyId":"offline-access","SecretAccessKey":"offline-secret"}' ;;
            sts) printf '%s\\n' $'111122223333\\tarn:aws:sts::111122223333:assumed-role/Operator/renewed' ;;
            ssm) exit \(code) ;;
            *) exit 90 ;;
        esac
        """
        let plugin = "#!/bin/bash\nset -euo pipefail\n\(guardLine)\nprintf '%s\\n' 1.2.498.0\n"
        for (name, body) in [("aws", cli), ("session-manager-plugin", plugin)] {
            let url = root.appendingPathComponent(name)
            try Data(body.utf8).write(to: url)
            XCTAssertEqual(chmod(url.path, 0o700), 0)
        }
    }

    private func execute(body: String, script: URL, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", body, script.path] + arguments
        let output = Pipe()
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func directory() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/ssm-script-cleanup/handoff-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
