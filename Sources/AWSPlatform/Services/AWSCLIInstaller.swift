import CryptoKit
import Darwin
import Foundation

struct AWSCLIInstaller: Sendable {
    typealias Downloader = @Sendable (URL, URL, Int) async throws -> Void
    typealias Verifier = @Sendable (URL) async throws -> Void
    typealias Runner = @Sendable (AWSCLIInstallCommand) async throws -> AWSCLIInstallProcessResult

    static let maximumPackageBytes = 256 * 1024 * 1024
    var temporaryRoot = FileManager.default.temporaryDirectory
    var download: Downloader = { source, target, maximum in
        try await AWSCLIHTTPClient().download(from: source, to: target, maximumBytes: maximum)
    }
    var verify: Verifier = { try await Self.verifyPackage($0) }
    var run: Runner = { try await AWSCLIInstallProcess.run($0) }
    var validateInstallation: @Sendable (AWSCLIInstallation) throws -> Void = { installation in
        guard installation.executableURL.resolvingSymlinksInPath() == installation.resolvedURL,
              FileManager.default.isExecutableFile(atPath: installation.executableURL.path) else {
            throw AWSCLIUpdateError.installationChanged
        }
        if case .homebrew(let prefix, let executable) = installation.source {
            let accepted = [prefix.appendingPathComponent("bin/brew").path,
                            prefix.appendingPathComponent("Homebrew/bin/brew").path]
            guard FileManager.default.isExecutableFile(atPath: executable.path),
                  accepted.contains(executable.resolvingSymlinksInPath().path) else {
                throw AWSCLIUpdateError.installationChanged
            }
        }
    }

    func update(_ installation: AWSCLIInstallation, to version: AWSCLIVersion,
                progress: @escaping @Sendable (AWSCLIUpdatePhase) -> Void) async throws {
        try Task.checkCancellation()
        guard installation.version.major == 2, version.major == 2, version > installation.version else {
            throw AWSCLIUpdateError.invalidVersion
        }
        try Self.validateSource(installation)
        try validateInstallation(installation)
        switch installation.source {
        case .officialPackage:
            try await installPackage(installation, version: version, progress: progress)
        case .homebrew(_, let executable):
            try Task.checkCancellation()
            // Both commands share an uncancelled lifetime once package maintenance starts.
            try await Task.detached(priority: .utility) {
                progress(.refreshingHomebrew)
                try await checkedRun(AWSCLIInstallCommand(
                    executable: executable, arguments: ["update"],
                    environment: AWSCLIInstallProcess.environment(homebrew: true)
                ))
                try validateInstallation(installation)
                progress(.installing)
                try await checkedRun(AWSCLIInstallCommand(
                    executable: executable, arguments: ["upgrade", "--formula", "awscli"],
                    environment: AWSCLIInstallProcess.environment(homebrew: true)
                ))
            }.value
        case .unmanaged:
            throw AWSCLIUpdateError.unsupportedInstallation
        }
    }

    private func installPackage(_ installation: AWSCLIInstallation, version: AWSCLIVersion,
                                progress: @escaping @Sendable (AWSCLIUpdatePhase) -> Void) async throws {
        let stage = try AWSCLIPackageStage(root: temporaryRoot)
        defer { stage.cleanup() }
        guard let url = URL(string: "https://awscli.amazonaws.com/AWSCLIV2-\(version).pkg") else {
            throw AWSCLIUpdateError.invalidVersion
        }
        progress(.downloading)
        do { try await download(url, stage.packageURL, Self.maximumPackageBytes) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AWSCLIUpdateError.downloadFailed }
        try Task.checkCancellation()
        let snapshot = try stage.snapshot()
        progress(.verifyingPackage)
        do { try await verify(stage.packageURL) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AWSCLIUpdateError.validationFailed }
        guard try stage.snapshot() == snapshot else { throw AWSCLIUpdateError.validationFailed }
        try validateInstallation(installation)
        try Task.checkCancellation()
        progress(.installing)
        let command = AWSCLIInstallCommand(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", Self.authorizationScript(package: stage.packageURL, snapshot: snapshot)],
            environment: AWSCLIInstallProcess.environment()
        )
        let result: AWSCLIInstallProcessResult
        do { result = try await run(command) }
        catch is CancellationError { throw CancellationError() }
        catch { throw AWSCLIUpdateError.updateFailed }
        if result.status != 0 {
            let output = String(decoding: result.output, as: UTF8.self)
            if output.contains("AWSPLATFORM_AUTHORIZATION_CANCELLED") || output.contains("(-128)") {
                throw AWSCLIUpdateError.authorizationCancelled
            }
            throw AWSCLIUpdateError.updateFailed
        }
    }

    private func checkedRun(_ command: AWSCLIInstallCommand) async throws {
        do {
            guard try await run(command).status == 0 else { throw AWSCLIUpdateError.updateFailed }
        } catch { throw AWSCLIUpdateError.updateFailed }
    }

    private static func validateSource(_ installation: AWSCLIInstallation) throws {
        guard getuid() != 0 else { throw AWSCLIUpdateError.unsupportedInstallation }
        let entries = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"]
        guard entries.contains(installation.executableURL.path) else { throw AWSCLIUpdateError.unsupportedInstallation }
        switch installation.source {
        case .officialPackage:
            guard AWSCLIInspector.isOfficialPath(installation.resolvedURL, version: installation.version) else {
                throw AWSCLIUpdateError.unsupportedInstallation
            }
        case .homebrew(let prefix, let executable):
            guard ["/opt/homebrew", "/usr/local"].contains(prefix.path),
                  executable == prefix.appendingPathComponent("bin/brew"),
                  installation.executableURL == prefix.appendingPathComponent("bin/aws"),
                  AWSCLIInspector.homebrewPrefix(for: installation.resolvedURL, version: installation.version)?.path == prefix.path else {
                throw AWSCLIUpdateError.unsupportedInstallation
            }
        case .unmanaged:
            throw AWSCLIUpdateError.unsupportedInstallation
        }
    }

    static func verifyPackage(_ url: URL) async throws {
        do {
            let output = try await CredentialProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/sbin/pkgutil"),
                arguments: ["--check-signature", url.path], environment: AWSCLIInstallProcess.environment(),
                timeout: .seconds(30), outputLimit: 32 * 1024, captureStandardError: true
            )
            guard isTrustedSignature(output) else { throw AWSCLIUpdateError.validationFailed }
        } catch is CancellationError { throw CancellationError() }
        catch { throw AWSCLIUpdateError.validationFailed }
    }

    static func isTrustedSignature(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("Status: signed by a developer certificate issued by Apple for distribution")
            && text.split(separator: "\n").contains { line in
                let value = line.trimmingCharacters(in: .whitespaces)
                return value.hasPrefix("1. Developer ID Installer: ") && value.hasSuffix(" (94KV3E626L)")
            }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func authorizationScript(package: URL, snapshot: AWSCLIPackageSnapshot) -> String {
        let rootCommand = privilegedShellScript(package: package, snapshot: snapshot)
        let command = "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/root USER=root LOGNAME=root LANG=C LC_ALL=C /bin/sh -c " + shellQuote(rootCommand)
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return """
        try
            do shell script "\(escaped)" with administrator privileges
        on error messageText number errorNumber
            if errorNumber is -128 then error "AWSPLATFORM_AUTHORIZATION_CANCELLED" number -128
            error "AWSPLATFORM_INSTALLATION_FAILED" number 1
        end try
        """
    }

    static func privilegedShellScript(package: URL, snapshot: AWSCLIPackageSnapshot) -> String {
        """
        set -eu
        umask 077
        source_pkg=\(shellQuote(package.path))
        source_dir=\(shellQuote(package.deletingLastPathComponent().path))
        [ ! -L "$source_dir" ] && [ ! -L "$source_pkg" ]
        [ "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l:%HT' "$source_dir")" = \(shellQuote(snapshot.directoryIdentity)) ]
        [ "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l:%HT:%z' "$source_pkg")" = \(shellQuote(snapshot.fileIdentity)) ]
        exec 3< "$source_pkg"
        [ "$(/usr/bin/stat -L -f '%i:%u:%Lp:%l:%HT:%z' /dev/fd/3)" = \(shellQuote(snapshot.descriptorIdentity)) ]
        root_dir=$(/usr/bin/mktemp -d /private/tmp/awsplatform-cli-install.XXXXXXXX)
        trap '/bin/rm -rf -- "$root_dir"' EXIT HUP INT TERM
        [ "$(/usr/bin/stat -f '%u:%Lp:%HT' "$root_dir")" = '0:700:Directory' ]
        root_pkg="$root_dir/AWSCLIV2.pkg"
        [ \(snapshot.copyBlocks) -gt 0 ]
        /bin/dd bs=65536 count=\(snapshot.copyBlocks) <&3 > "$root_pkg" 2>/dev/null
        exec 3<&-
        /bin/chmod 400 "$root_pkg"
        [ ! -L "$source_dir" ] && [ ! -L "$source_pkg" ]
        [ "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l:%HT' "$source_dir")" = \(shellQuote(snapshot.directoryIdentity)) ]
        [ "$(/usr/bin/stat -f '%d:%i:%u:%Lp:%l:%HT:%z' "$source_pkg")" = \(shellQuote(snapshot.fileIdentity)) ]
        digest=$(/usr/bin/shasum -a 256 "$root_pkg")
        [ "${digest%% *}" = \(shellQuote(snapshot.digest)) ]
        signature=$(/usr/sbin/pkgutil --check-signature "$root_pkg" 2>&1)
        case "$signature" in *'Status: signed by a developer certificate issued by Apple for distribution'*) ;; *) exit 70 ;; esac
        /usr/bin/printf '%s\\n' "$signature" | /usr/bin/grep -Eq '^[[:space:]]*1\\. Developer ID Installer: .+ \\(94KV3E626L\\)$'
        /usr/sbin/installer -pkg "$root_pkg" -target /
        """
    }
}

struct AWSCLIPackageSnapshot: Equatable, Sendable {
    let digest: String
    let fileIdentity: String
    let directoryIdentity: String

    // macOS /dev/fd reports a synthetic device number. Path checks retain the
    // real device, while the opened descriptor binds inode, owner, mode and size.
    var descriptorIdentity: String { fileIdentity.split(separator: ":", maxSplits: 1).dropFirst().joined() }

    var copyBlocks: Int64 {
        guard let size = fileIdentity.split(separator: ":").last.flatMap({ Int64($0) }),
              size > 0, size <= AWSCLIInstaller.maximumPackageBytes else { return 0 }
        return (size + 65_535) / 65_536
    }
}

final class AWSCLIPackageStage {
    let directory: URL
    let packageURL: URL
    private let root: Int32
    private let descriptor: Int32
    private let name: String
    private let directoryInfo: stat
    private var fileInfo: stat?

    init(root url: URL) throws {
        let canonical = url.resolvingSymlinksInPath()
        root = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw AWSCLIUpdateError.validationFailed }
        name = "awsplatform-cli-update-" + UUID().uuidString
        directory = canonical.appendingPathComponent(name, isDirectory: true)
        packageURL = directory.appendingPathComponent("AWSCLIV2.pkg")
        guard mkdirat(root, name, S_IRWXU) == 0 else { close(root); throw AWSCLIUpdateError.validationFailed }
        descriptor = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            _ = unlinkat(root, name, AT_REMOVEDIR); close(root); throw AWSCLIUpdateError.validationFailed
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else {
            close(descriptor); close(root); throw AWSCLIUpdateError.validationFailed
        }
        directoryInfo = info
    }

    deinit { close(descriptor); close(root) }

    func snapshot() throws -> AWSCLIPackageSnapshot {
        guard matches(root, name, directoryInfo) else { throw AWSCLIUpdateError.validationFailed }
        let file = openat(descriptor, "AWSCLIV2.pkg", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw AWSCLIUpdateError.validationFailed }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, [0o400, 0o600].contains(info.st_mode & 0o7777),
              info.st_size > 0, info.st_size <= AWSCLIInstaller.maximumPackageBytes,
              matches(descriptor, "AWSCLIV2.pkg", info), fchmod(file, S_IRUSR) == 0 else {
            throw AWSCLIUpdateError.validationFailed
        }
        // Hold inode identity for cleanup before hashing or verification can fail.
        guard fstat(file, &info) == 0 else { throw AWSCLIUpdateError.validationFailed }
        if let previous = fileInfo, previous.st_dev != info.st_dev || previous.st_ino != info.st_ino {
            throw AWSCLIUpdateError.validationFailed
        }
        fileInfo = info
        var hash = SHA256()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        var total: Int64 = 0
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw AWSCLIUpdateError.validationFailed }
            total += Int64(count)
            guard total <= AWSCLIInstaller.maximumPackageBytes else { throw AWSCLIUpdateError.validationFailed }
            hash.update(data: Data(bytes.prefix(count)))
        }
        var after = stat()
        guard fstat(file, &after) == 0, total == info.st_size,
              after.st_size == info.st_size,
              after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec,
              matches(descriptor, "AWSCLIV2.pkg", info),
              matches(root, name, directoryInfo) else { throw AWSCLIUpdateError.validationFailed }
        return AWSCLIPackageSnapshot(
            digest: hash.finalize().map { String(format: "%02x", $0) }.joined(),
            fileIdentity: "\(info.st_dev):\(info.st_ino):\(info.st_uid):400:\(info.st_nlink):Regular File:\(info.st_size)",
            directoryIdentity: "\(directoryInfo.st_dev):\(directoryInfo.st_ino):\(directoryInfo.st_uid):700:\(directoryInfo.st_nlink):Directory"
        )
    }

    func cleanup(beforeIsolation: (() -> Void)? = nil) {
        // The downloader owns its partial file. We may only remove the inode claimed
        // by snapshot(), never an arbitrary replacement with plausible permissions.
        if let fileInfo { removeSnapshot(fileInfo, beforeIsolation: beforeIsolation) }
        if matches(root, name, directoryInfo) { _ = unlinkat(root, name, AT_REMOVEDIR) }
    }

    private func removeSnapshot(_ expected: stat, beforeIsolation: (() -> Void)?) {
        guard matches(root, name, directoryInfo) else { return }
        let isolatedName = ".cleanup-" + UUID().uuidString
        guard mkdirat(descriptor, isolatedName, S_IRWXU) == 0 else { return }
        let isolated = openat(descriptor, isolatedName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard isolated >= 0 else { return }
        defer { close(isolated) }
        var isolatedInfo = stat()
        guard fstat(isolated, &isolatedInfo) == 0, isolatedInfo.st_uid == getuid(),
              isolatedInfo.st_mode & 0o7777 == 0o700 else { return }
        var removed = false
        defer {
            if removed, matches(descriptor, isolatedName, isolatedInfo) {
                _ = unlinkat(descriptor, isolatedName, AT_REMOVEDIR)
            }
        }
        beforeIsolation?()
        guard renameatx_np(descriptor, "AWSCLIV2.pkg", isolated, "AWSCLIV2.pkg", UInt32(RENAME_EXCL)) == 0 else {
            removed = true; return
        }
        let file = openat(isolated, "AWSCLIV2.pkg", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        func restore() { _ = renameatx_np(isolated, "AWSCLIV2.pkg", descriptor, "AWSCLIV2.pkg", UInt32(RENAME_EXCL)) }
        guard file >= 0 else { restore(); return }
        defer { close(file) }
        var actual = stat()
        guard fstat(file, &actual) == 0, actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino,
              actual.st_uid == getuid(), actual.st_nlink == 1, actual.st_mode & S_IFMT == S_IFREG,
              [0o400, 0o600].contains(actual.st_mode & 0o7777),
              matches(isolated, "AWSCLIV2.pkg", actual), matches(descriptor, isolatedName, isolatedInfo),
              unlinkat(isolated, "AWSCLIV2.pkg", 0) == 0 else { restore(); return }
        removed = true
    }

    private func matches(_ parent: Int32, _ name: String, _ expected: stat) -> Bool {
        var actual = stat()
        return fstatat(parent, name, &actual, AT_SYMLINK_NOFOLLOW) == 0
            && actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
            && actual.st_uid == getuid() && actual.st_mode & S_IFMT == expected.st_mode & S_IFMT
            && actual.st_mode & 0o7777 == expected.st_mode & 0o7777
    }
}
