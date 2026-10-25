import Foundation
import Security

struct AWSCLIInspector: Sendable {
    typealias Runner = @Sendable (URL, [String], [String: String]) async throws -> Data
    typealias OfficialVerifier = @Sendable (URL, AWSCLIVersion) async -> Bool
    typealias HomebrewVerifier = @Sendable (URL, AWSCLIVersion) -> Bool

    private let candidates: [String]
    private let runner: Runner
    private let officialVerifier: OfficialVerifier
    private let homebrewVerifier: HomebrewVerifier

    init(
        candidates: [String] = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"],
        runner: @escaping Runner = { executable, arguments, environment in
            try await CredentialProcessRunner.run(
                executable: executable, arguments: arguments, environment: environment,
                timeout: .seconds(10), outputLimit: 8 * 1024, captureStandardError: true
            )
        },
        officialVerifier: @escaping OfficialVerifier = { url, version in
            await AWSCLIInspector.verifyOfficialPackage(url, version)
        },
        homebrewVerifier: @escaping HomebrewVerifier = { url, version in
            AWSCLIInspector.verifyHomebrew(url, version)
        }
    ) {
        self.candidates = candidates
        self.runner = runner
        self.officialVerifier = officialVerifier
        self.homebrewVerifier = homebrewVerifier
    }

    func inspect() async throws -> AWSCLIInstallation? {
        try Task.checkCancellation()
        guard let executable = AWSCLIConfiguration.executable(candidates: candidates) else { return nil }
        let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
        do {
            let output = try await runner(executable, ["--version"], Self.processEnvironment())
            guard let text = String(data: output, encoding: .utf8),
                  let version = AWSCLIVersion.parseCLIOutput(text) else { throw AWSCLIUpdateError.invalidVersion }
            var source = AWSCLIInstallSource.unmanaged
            if version.major == 2, Self.isOfficialPath(resolved, version: version),
               await officialVerifier(resolved, version) {
                source = .officialPackage
            } else if version.major == 2, let prefix = Self.homebrewPrefix(for: resolved, version: version),
                      homebrewVerifier(resolved, version) {
                source = .homebrew(prefix: prefix, executable: prefix.appendingPathComponent("bin/brew"))
            }
            // The entry point must still identify the installation inspected above.
            guard AWSCLIConfiguration.executable(candidates: candidates) == executable,
                  executable.resolvingSymlinksInPath().standardizedFileURL == resolved else {
                throw AWSCLIUpdateError.installationChanged
            }
            return AWSCLIInstallation(executableURL: executable, resolvedURL: resolved, version: version, source: source)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AWSCLIUpdateError {
            throw error
        } catch {
            throw AWSCLIUpdateError.checkFailed
        }
    }

    static func processEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = base.filter { ["HOME", "USER", "LOGNAME", "TMPDIR"].contains($0.key) }
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        result["LANG"] = "en_US.UTF-8"
        result["LC_ALL"] = "en_US.UTF-8"
        result["AWS_CLI_AUTO_PROMPT"] = "off"
        result["AWS_PAGER"] = ""
        // CLI startup loads config and plugins even for --version.
        result["AWS_CONFIG_FILE"] = "/dev/null"
        result["AWS_SHARED_CREDENTIALS_FILE"] = "/dev/null"
        result["AWS_EC2_METADATA_DISABLED"] = "true"
        return result
    }

    static func isOfficialPath(_ url: URL, version: AWSCLIVersion) -> Bool {
        let path = url.standardizedFileURL.path
        return path == "/usr/local/aws-cli/aws"
            || path == "/usr/local/aws-cli/v2/\(version)/bin/aws"
    }

    static func homebrewPrefix(for url: URL, version: AWSCLIVersion) -> URL? {
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let components = url.standardizedFileURL.pathComponents
            let root = URL(fileURLWithPath: prefix).pathComponents + ["Cellar", "awscli"]
            guard components.starts(with: root),
                  components.count == root.count + 3 || components.count == root.count + 4 else { continue }
            let revision = components[root.count].split(separator: "_", omittingEmptySubsequences: false)
            guard revision.count == 1 || (revision.count == 2 && !revision[1].isEmpty
                && revision[1].utf8.allSatisfy { (48...57).contains($0) }),
                  AWSCLIVersion(String(revision[0])) == version else { continue }
            let suffix = Array(components.dropFirst(root.count + 1))
            guard suffix == ["bin", "aws"] || suffix == ["libexec", "bin", "aws"] else { continue }
            return URL(fileURLWithPath: prefix, isDirectory: true)
        }
        return nil
    }

    private static func verifyOfficialPackage(_ executable: URL, _ version: AWSCLIVersion) async -> Bool {
        guard isOfficialPath(executable, version: version), verifyAWSSignature(executable) else { return false }
        guard let receipt = try? await CredentialProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/pkgutil"),
            arguments: ["--pkg-info-plist", "com.amazon.aws.cli2"], environment: processEnvironment(),
            timeout: .seconds(10), outputLimit: 8 * 1024
        ) else { return false }
        return officialReceiptMatches(receipt, version: version)
    }

    static func officialReceiptMatches(_ data: Data, version: AWSCLIVersion) -> Bool {
        guard let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              dictionary["pkgid"] as? String == "com.amazon.aws.cli2",
              dictionary["volume"] as? String == "/",
              let location = dictionary["install-location"] as? String,
              ["usr/local", "/usr/local"].contains(location),
              let receiptVersion = dictionary["pkg-version"] as? String else { return false }
        return AWSCLIVersion(receiptVersion) == version
    }

    private static func verifyAWSSignature(_ executable: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: 0)
        guard SecStaticCodeCreateWithPath(executable as CFURL, flags, &code) == errSecSuccess,
              SecRequirementCreateWithString(
                "anchor apple generic and certificate leaf[subject.OU] = \"94KV3E626L\"" as CFString,
                flags, &requirement
              ) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    private static func verifyHomebrew(_ executable: URL, _ version: AWSCLIVersion) -> Bool {
        guard let prefix = homebrewPrefix(for: executable, version: version) else { return false }
        let brew = prefix.appendingPathComponent("bin/brew")
        let brewResolved = brew.resolvingSymlinksInPath().standardizedFileURL.path
        let acceptedBrewPaths = [prefix.appendingPathComponent("Homebrew/bin/brew").path,
                                 prefix.appendingPathComponent("bin/brew").path]
        guard FileManager.default.isExecutableFile(atPath: brew.path), acceptedBrewPaths.contains(brewResolved) else {
            return false
        }
        let kegComponentIndex = prefix.pathComponents.count + 2
        let kegComponents = executable.pathComponents.prefix(kegComponentIndex + 1)
        let receiptURL = URL(fileURLWithPath: NSString.path(withComponents: Array(kegComponents)))
            .appendingPathComponent("INSTALL_RECEIPT.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: receiptURL.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 128 * 1024,
              let data = try? Data(contentsOf: receiptURL) else { return false }
        return homebrewReceiptMatches(data, version: version)
    }

    static func homebrewReceiptMatches(_ data: Data, version: AWSCLIVersion) -> Bool {
        guard let receipt = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              receipt["homebrew_version"] as? String != nil,
              let source = receipt["source"] as? [String: Any],
              let versions = source["versions"] as? [String: Any],
              let stable = versions["stable"] as? String,
              AWSCLIVersion(stable) == version else { return false }
        return true
    }
}
