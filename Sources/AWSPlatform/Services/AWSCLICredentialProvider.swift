import Foundation
import SotoCore

/// Uses the installed AWS CLI for Profile credential flows that Soto cannot
/// resolve, keeping credential output in a bounded private memory pipe.
struct AWSCLICredentialProvider: CredentialProvider {
    typealias Runner = @Sendable ([String], [String: String]) async throws -> Data

    let profile: String
    let paths: AWSConfigurationPaths
    var runner: Runner = { arguments, environment in
        try await Self.run(arguments: arguments, environment: environment)
    }

    func getCredential(logger: Logger) async throws -> Credential {
        let environment = AWSCLIConfiguration.environment(paths: paths)
        let arguments = [
            "configure", "export-credentials", "--profile", profile, "--format", "process",
            "--no-cli-pager", "--no-cli-auto-prompt", "--cli-connect-timeout", "10",
            "--cli-read-timeout", "20"
        ]
        do {
            let data = try await runner(arguments, environment)
            try Task.checkCancellation()
            return try Self.decode(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Never surface process output or JSON decoding diagnostics.
            throw ExportError.unavailable
        }
    }

    static func decode(_ data: Data) throws -> RotatingCredential {
        struct Payload: Decodable {
            let Version: Int
            let AccessKeyId: String
            let SecretAccessKey: String
            let SessionToken: String
            let Expiration: String
        }
        let formatter = ISO8601DateFormatter()
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.Version == 1, !payload.AccessKeyId.isEmpty,
              !payload.SecretAccessKey.isEmpty, !payload.SessionToken.isEmpty,
              let expiration = formatter.date(from: payload.Expiration)
                ?? fractionalFormatter.date(from: payload.Expiration),
              expiration > Date() else { throw ExportError.unavailable }
        return RotatingCredential(
            accessKeyId: payload.AccessKeyId,
            secretAccessKey: payload.SecretAccessKey,
            sessionToken: payload.SessionToken,
            expiration: expiration
        )
    }

    private static func run(arguments: [String], environment: [String: String]) async throws -> Data {
        guard let executable = AWSCLIConfiguration.executable() else {
            throw ExportError.unavailable
        }
        return try await CredentialProcessRunner.run(
            executable: executable, arguments: arguments, environment: environment
        )
    }

    enum ExportError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "Unable to load Profile credentials. Install AWS CLI v2 in /opt/homebrew/bin or /usr/local/bin, check the Profile and AWS_CONFIG_FILE configuration, complete SSO login if required, then retry."
        }
    }
}
