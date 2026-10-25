import Darwin
import Foundation
import XCTest
@testable import AWSPlatform

final class AWSCLIInstallerTests: XCTestCase {
    private let old = AWSCLIVersion("2.37.9")!
    private let target = AWSCLIVersion("2.38.5")!

    func testOfficialDownloadIsVersionBoundAndInstallerOnlyReceivesVerifiedSnapshot() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        var installer = fixture(root: root, recorder: recorder)
        installer.verify = { url in
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "signed fixture")
            let info = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((info[.posixPermissions] as? NSNumber)?.intValue, 0o400)
        }
        try await installer.update(official(), to: target) { recorder.phase($0) }
        XCTAssertEqual(recorder.downloads.first?.0.absoluteString, "https://awscli.amazonaws.com/AWSCLIV2-2.38.5.pkg")
        XCTAssertEqual(recorder.downloads.first?.1, 256 * 1024 * 1024)
        let command = try XCTUnwrap(recorder.commands.first)
        XCTAssertEqual(command.executable.path, "/usr/bin/osascript")
        XCTAssertEqual(command.arguments.first, "-e")
        XCTAssertTrue(command.arguments[1].contains("with administrator privileges"))
        XCTAssertTrue(command.arguments[1].contains("94KV3E626L"))
        XCTAssertTrue(command.arguments[1].contains("/usr/sbin/installer"))
        XCTAssertFalse(command.arguments[1].contains("password"))
        XCTAssertEqual(recorder.phases, [.downloading, .verifyingPackage, .installing])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testUnknownSourceAndNonSystemOfficialPathsNeverDownloadOrRun() async throws {
        let recorder = Recorder()
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = fixture(root: root, recorder: recorder)
        let installations = [
            AWSCLIInstallation(executableURL: URL(fileURLWithPath: "/usr/local/bin/aws"),
                               resolvedURL: URL(fileURLWithPath: "/custom/aws"), version: old, source: .unmanaged),
            AWSCLIInstallation(executableURL: URL(fileURLWithPath: "/custom/aws"),
                               resolvedURL: URL(fileURLWithPath: "/usr/local/aws-cli/aws"), version: old, source: .officialPackage)
        ]
        for installation in installations {
            await expect(.unsupportedInstallation) { try await installer.update(installation, to: self.target) { _ in } }
        }
        XCTAssertTrue(recorder.downloads.isEmpty)
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    func testEqualOlderAndOtherMajorTargetsAreRejected() async throws {
        let recorder = Recorder()
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = fixture(root: root, recorder: recorder)
        for version in [old, AWSCLIVersion("2.1.0")!, AWSCLIVersion("3.0.0")!] {
            await expect(.invalidVersion) { try await installer.update(self.official(), to: version) { _ in } }
        }
        XCTAssertTrue(recorder.downloads.isEmpty)
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    func testSignatureFailureCleansDownloadedPackageAndNeverStartsAuthorization() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        var installer = fixture(root: root, recorder: recorder)
        installer.verify = { _ in throw FixtureError.privateFailure }
        await expect(.validationFailed) { try await installer.update(self.official(), to: self.target) { _ in } }
        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testInPlacePackageMutationAfterSignatureCheckIsRejected() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        var installer = fixture(root: root, recorder: recorder)
        installer.verify = { url in
            XCTAssertEqual(chmod(url.path, 0o600), 0)
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: Data("tamper".utf8))
            try handle.close()
            XCTAssertEqual(chmod(url.path, 0o400), 0)
        }
        await expect(.validationFailed) { try await installer.update(self.official(), to: self.target) { _ in } }
        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testPackagePathReplacementIsRejectedAndUnknownReplacementPreserved() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        var installer = fixture(root: root, recorder: recorder)
        installer.verify = { url in
            let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement")
            try Data("signed fixture".utf8).write(to: replacement)
            XCTAssertEqual(chmod(replacement.path, 0o600), 0)
            XCTAssertEqual(rename(replacement.path, url.path), 0)
        }
        await expect(.validationFailed) { try await installer.update(self.official(), to: self.target) { _ in } }
        XCTAssertTrue(recorder.commands.isEmpty)
        let directory = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("AWSCLIV2.pkg"), encoding: .utf8), "signed fixture")
    }

    func testDownloadedSymlinkHardlinkAndWorldReadablePackageAreRejected() async throws {
        for kind in 0..<3 {
            let root = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let recorder = Recorder()
            var installer = fixture(root: root, recorder: recorder)
            installer.download = { _, destination, _ in
                if kind < 2 {
                    let other = root.appendingPathComponent("other")
                    try Data("fixture".utf8).write(to: other)
                    XCTAssertEqual(chmod(other.path, 0o600), 0)
                    if kind == 0 { XCTAssertEqual(symlink(other.path, destination.path), 0) }
                    else { XCTAssertEqual(link(other.path, destination.path), 0) }
                } else {
                    try Data("fixture".utf8).write(to: destination)
                    XCTAssertEqual(chmod(destination.path, 0o644), 0)
                }
            }
            await expect(.validationFailed) { try await installer.update(self.official(), to: self.target) { _ in } }
            XCTAssertTrue(recorder.commands.isEmpty)
        }
    }

    func testFailedDownloadDoesNotClaimUnknownPartialOrExposeRawError() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        var installer = fixture(root: root, recorder: recorder)
        installer.download = { _, destination, _ in
            try Data("partial".utf8).write(to: destination)
            XCTAssertEqual(chmod(destination.path, 0o600), 0)
            throw FixtureError.privateFailure
        }
        await expect(.downloadFailed) { try await installer.update(self.official(), to: self.target) { _ in } }
        XCTAssertTrue(recorder.commands.isEmpty)
        let directory = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("AWSCLIV2.pkg"), encoding: .utf8), "partial")
    }

    func testCleanupDoesNotDeleteReplacementInsertedBeforeItsClaim() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = try AWSCLIPackageStage(root: root)
        try Data("original".utf8).write(to: stage.packageURL)
        XCTAssertEqual(chmod(stage.packageURL.path, 0o600), 0)
        _ = try stage.snapshot()
        stage.cleanup {
            let replacement = stage.directory.appendingPathComponent("replacement")
            try! Data("preserve replacement".utf8).write(to: replacement)
            XCTAssertEqual(chmod(replacement.path, 0o600), 0)
            XCTAssertEqual(rename(replacement.path, stage.packageURL.path), 0)
        }
        XCTAssertEqual(try String(contentsOf: stage.packageURL, encoding: .utf8), "preserve replacement")
    }

    func testAuthorizationCancellationAndInstallerFailureAreSanitizedAndCleaned() async throws {
        for cancelled in [true, false] {
            let root = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let recorder = Recorder()
            var installer = fixture(root: root, recorder: recorder)
            installer.run = { _ in
                AWSCLIInstallProcessResult(status: 1, output: Data((cancelled ? "User canceled. (-128)" : "private installer output").utf8), outputWasTruncated: false)
            }
            await expect(cancelled ? .authorizationCancelled : .updateFailed) {
                try await installer.update(self.official(), to: self.target) { _ in }
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    func testChangedInstallationBeforeAuthorizationIsRejected() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        var installer = fixture(root: root, recorder: recorder)
        installer.validateInstallation = { _ in
            if recorder.incrementValidation() > 1 { throw AWSCLIUpdateError.installationChanged }
        }
        await expect(.installationChanged) { try await installer.update(self.official(), to: self.target) { _ in } }
        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testHomebrewOnlyUpdatesItsDetectedPrefixAndFormula() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let installer = fixture(root: root, recorder: recorder)
        try await installer.update(brew(), to: target) { recorder.phase($0) }
        XCTAssertTrue(recorder.downloads.isEmpty)
        XCTAssertEqual(recorder.commands.map(\.arguments), [["update"], ["upgrade", "--formula", "awscli"]])
        XCTAssertEqual(Set(recorder.commands.map { $0.executable.path }), ["/opt/homebrew/bin/brew"])
        XCTAssertEqual(recorder.phases, [.refreshingHomebrew, .installing])
        for command in recorder.commands {
            XCTAssertEqual(command.environment["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"], "1")
            XCTAssertEqual(command.environment["HOMEBREW_NO_INSTALL_CLEANUP"], "1")
            XCTAssertFalse(command.arguments.contains("--overwrite"))
        }
    }

    func testHomebrewRefreshFailureDoesNotStartUpgrade() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        var installer = fixture(root: root, recorder: recorder)
        installer.run = { command in
            recorder.command(command)
            return AWSCLIInstallProcessResult(status: 8, output: Data("private brew output".utf8), outputWasTruncated: false)
        }
        await expect(.updateFailed) { try await installer.update(self.brew(), to: self.target) { _ in } }
        XCTAssertEqual(recorder.commands.map(\.arguments), [["update"]])
    }

    func testMismatchedHomebrewPrefixIsRejected() async throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = Recorder()
        let installer = fixture(root: root, recorder: recorder)
        let installation = AWSCLIInstallation(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/aws"),
            resolvedURL: URL(fileURLWithPath: "/opt/homebrew/Cellar/awscli/2.37.9/bin/aws"), version: old,
            source: .homebrew(prefix: URL(fileURLWithPath: "/opt/homebrew"), executable: URL(fileURLWithPath: "/usr/local/bin/brew")))
        await expect(.unsupportedInstallation) { try await installer.update(installation, to: self.target) { _ in } }
        XCTAssertTrue(recorder.commands.isEmpty)
    }

    func testSignatureRequiresTrustedStatusAndAWSInstallerLeaf() {
        let valid = "Status: signed by a developer certificate issued by Apple for distribution\n  1. Developer ID Installer: AMZN Mobile LLC (94KV3E626L)\n"
        XCTAssertTrue(AWSCLIInstaller.isTrustedSignature(Data(valid.utf8)))
        XCTAssertFalse(AWSCLIInstaller.isTrustedSignature(Data(valid.replacingOccurrences(of: "94KV3E626L", with: "AAAAAAAAAA").utf8)))
        XCTAssertFalse(AWSCLIInstaller.isTrustedSignature(Data(valid.replacingOccurrences(of: "Developer ID Installer", with: "Developer ID Application").utf8)))
        XCTAssertFalse(AWSCLIInstaller.isTrustedSignature(Data(valid.replacingOccurrences(of: "Status: signed", with: "Status: expired").utf8)))
        XCTAssertFalse(AWSCLIInstaller.isTrustedSignature(Data(valid.replacingOccurrences(of: "1. Developer", with: "2. Developer").utf8)))
    }

    func testPrivilegedCopyRechecksInodeHashAndSignatureBeforeInstalling() throws {
        let snapshot = AWSCLIPackageSnapshot(digest: String(repeating: "a", count: 64),
            fileIdentity: "1:2:501:400:1:Regular File:7", directoryIdentity: "1:3:501:700:2:Directory")
        let url = URL(fileURLWithPath: "/private/tmp/fixture's quoted/AWSCLIV2.pkg")
        let script = AWSCLIInstaller.privilegedShellScript(package: url, snapshot: snapshot)
        XCTAssertTrue(script.contains("exec 3<"))
        XCTAssertTrue(script.contains("stat -L -f"))
        XCTAssertTrue(script.contains("root_dir=$(/usr/bin/mktemp -d /private/tmp/"))
        XCTAssertTrue(script.contains("'0:700:Directory'"))
        XCTAssertTrue(script.contains("trap '/bin/rm -rf"))
        XCTAssertTrue(script.contains("/bin/dd bs=65536 count=1"))
        let digest = try XCTUnwrap(script.range(of: "digest=$(/usr/bin/shasum"))
        let signature = try XCTUnwrap(script.range(of: "signature=$(/usr/sbin/pkgutil"))
        let install = try XCTUnwrap(script.range(of: "/usr/sbin/installer -pkg"))
        XCTAssertLessThan(digest.lowerBound, signature.lowerBound)
        XCTAssertLessThan(signature.lowerBound, install.lowerBound)
        XCTAssertTrue(script.contains("fixture'\\''s quoted"))
        XCTAssertFalse(script.contains("curl"))
    }

    private func official() -> AWSCLIInstallation {
        AWSCLIInstallation(executableURL: URL(fileURLWithPath: "/usr/local/bin/aws"),
            resolvedURL: URL(fileURLWithPath: "/usr/local/aws-cli/aws"), version: old, source: .officialPackage)
    }

    private func brew() -> AWSCLIInstallation {
        AWSCLIInstallation(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/aws"),
            resolvedURL: URL(fileURLWithPath: "/opt/homebrew/Cellar/awscli/2.37.9/bin/aws"), version: old,
            source: .homebrew(prefix: URL(fileURLWithPath: "/opt/homebrew"), executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew")))
    }

    private func fixture(root: URL, recorder: Recorder) -> AWSCLIInstaller {
        AWSCLIInstaller(temporaryRoot: root, download: { source, destination, limit in
            recorder.download(source, limit)
            try Data("signed fixture".utf8).write(to: destination, options: .withoutOverwriting)
            guard chmod(destination.path, 0o600) == 0 else { throw FixtureError.privateFailure }
        }, verify: { _ in }, run: { command in
            recorder.command(command)
            return AWSCLIInstallProcessResult(status: 0, output: Data(), outputWasTruncated: false)
        }, validateInstallation: { _ in })
    }

    private func expect(_ expected: AWSCLIUpdateError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected sanitized failure") }
        catch {
            XCTAssertEqual(error as? AWSCLIUpdateError, expected)
            XCTAssertFalse(error.localizedDescription.contains("private"))
        }
    }

    private func makeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/aws-cli-update/installer-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private enum FixtureError: Error { case privateFailure }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var commandValues: [AWSCLIInstallCommand] = []
        private var downloadValues: [(URL, Int)] = []
        private var phaseValues: [AWSCLIUpdatePhase] = []
        private var validations = 0
        var commands: [AWSCLIInstallCommand] { lock.withLock { commandValues } }
        var downloads: [(URL, Int)] { lock.withLock { downloadValues } }
        var phases: [AWSCLIUpdatePhase] { lock.withLock { phaseValues } }
        func command(_ value: AWSCLIInstallCommand) { lock.withLock { commandValues.append(value) } }
        func download(_ url: URL, _ maximum: Int) { lock.withLock { downloadValues.append((url, maximum)) } }
        func phase(_ value: AWSCLIUpdatePhase) { lock.withLock { phaseValues.append(value) } }
        func incrementValidation() -> Int { lock.withLock { validations += 1; return validations } }
    }
}
