import Foundation

struct AWSCLIVersion: Equatable, Hashable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    static func parseCLIOutput(_ output: String) -> Self? {
        let fields = output.split(whereSeparator: { $0.isWhitespace })
        guard let first = fields.first, first.hasPrefix("aws-cli/") else { return nil }
        return Self(String(first.dropFirst("aws-cli/".count)))
    }
}

enum AWSCLIInstallSource: Equatable, Sendable {
    case officialPackage
    case homebrew(prefix: URL, executable: URL)
    case unmanaged

    var displayName: String {
        switch self {
        case .officialPackage: return "AWS official installer"
        case .homebrew: return "Homebrew"
        case .unmanaged: return "Unmanaged installation"
        }
    }

    var supportsAutomaticUpdate: Bool {
        switch self {
        case .officialPackage, .homebrew: return true
        case .unmanaged: return false
        }
    }
}

struct AWSCLIInstallation: Equatable, Sendable {
    let executableURL: URL
    let resolvedURL: URL
    let version: AWSCLIVersion
    let source: AWSCLIInstallSource
}

enum AWSCLIUpdatePhase: Equatable, Sendable {
    case downloading, verifyingPackage, installing, verifyingInstallation, refreshingHomebrew
}

enum AWSCLIUpdateError: Error, LocalizedError, Equatable, Sendable {
    case notInstalled, invalidVersion, unsupportedInstallation, checkFailed, downloadFailed
    case validationFailed, installationChanged, busy, authorizationCancelled, updateFailed

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "AWS CLI is not installed. Install AWS CLI v2 to continue."
        case .invalidVersion: return "AWS CLI returned an unsupported version."
        case .unsupportedInstallation: return "This AWS CLI installation must be updated manually."
        case .checkFailed: return "Could not check the AWS CLI version. Try again."
        case .downloadFailed: return "Could not download the AWS CLI update. Try again."
        case .validationFailed: return "The AWS CLI installer could not be verified. No update was installed."
        case .installationChanged: return "The AWS CLI installation changed. Check its version again."
        case .busy: return "AWS CLI is busy. Wait for active transfers, CLI operations or updates to finish, then retry."
        case .authorizationCancelled: return "AWS CLI update authorization was cancelled."
        case .updateFailed: return "The AWS CLI update did not complete. Check the installed version and try again."
        }
    }
}
