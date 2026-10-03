import Foundation
import SotoCore

/// Soto's SSO factory does not accept a config path. Delegate only that case to
/// the installed AWS CLI, keeping credential output in a private memory pipe.
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
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        let task = Task.detached {
            try Task.checkCancellation()
            try process.run()
            if Task.isCancelled { process.terminate() }
            let timeout = Task {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    if process.isRunning { process.terminate() }
                } catch {}
            }
            defer { timeout.cancel() }
            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw ExportError.unavailable }
            return data
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            if process.isRunning { process.terminate() }
        }
    }

    enum ExportError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "Unable to load SSO credentials from the custom configuration. Install AWS CLI v2 in /opt/homebrew/bin or /usr/local/bin, run aws sso login with the same AWS_CONFIG_FILE and profile, then retry."
        }
    }
}
