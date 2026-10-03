import Darwin
import Foundation

enum AWSCLIConfiguration {
    static func executable(candidates: [String] = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"]) -> URL? {
        candidates.first(where: FileManager.default.isExecutableFile).map { URL(fileURLWithPath: $0) }
    }

    static func environment(
        paths: AWSConfigurationPaths,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment["AWS_CONFIG_FILE"] = paths.config
        environment["AWS_SHARED_CREDENTIALS_FILE"] = paths.credentials
        environment["AWS_CLI_AUTO_PROMPT"] = "off"
        environment["AWS_PAGER"] = ""
        environment["AWS_CLI_HISTORY_FILE"] = "/dev/null"
        for key in ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
                    "AWS_SECURITY_TOKEN", "AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_ROLE_ARN"] {
            environment.removeValue(forKey: key)
        }
        return environment
    }
}

@MainActor
struct AWSSSOLoginService {
    typealias Runner = @MainActor ([String], [String: String]) async throws -> Void

    var runner: Runner = { arguments, environment in
        guard let executable = AWSCLIConfiguration.executable() else { throw LoginError.cliMissing }
        try await run(executable: executable, arguments: arguments, environment: environment)
    }

    func login(profile: String, paths: AWSConfigurationPaths) async throws {
        guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LoginError.invalidProfile
        }
        try Task.checkCancellation()
        do {
            // Pass each argument directly; profile names are never interpreted by a shell.
            try await runner(
                ["sso", "login", "--profile", profile, "--no-cli-pager", "--no-cli-auto-prompt"],
                AWSCLIConfiguration.environment(paths: paths)
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LoginError {
            throw error
        } catch {
            throw LoginError.failed
        }
    }

    static func run(
        executable: URL, arguments: [String], environment: [String: String],
        timeout: Duration = .seconds(300)
    ) async throws {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        // CLI output can include temporary authorization URLs. Never retain or log it.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw LoginError.launchFailed }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw LoginError.timedOut }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw LoginError.failed
            }
        } catch {
            // Cleanup must run even when the calling task has been cancelled.
            await Task { @MainActor in
                guard process.isRunning else { return }
                process.terminate()
                let stopDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while process.isRunning && ContinuousClock.now < stopDeadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                // Reap only this child. No browser or other AWS process is terminated.
                while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            }.value
            throw error
        }
    }

    enum LoginError: LocalizedError {
        case cliMissing, invalidProfile, launchFailed, failed, timedOut

        var errorDescription: String? {
            switch self {
            case .cliMissing:
                return "Install AWS CLI v2 in /opt/homebrew/bin or /usr/local/bin, then try SSO Login again."
            case .invalidProfile:
                return "Select an SSO profile before signing in."
            case .launchFailed:
                return "Unable to start AWS CLI. Check its installation and try again."
            case .failed:
                return "SSO login did not complete. Check browser authorization, network access and SSO configuration. You can also sign in from Terminal, then use Retry Connection."
            case .timedOut:
                return "SSO login timed out after waiting for browser authorization. Try again, or sign in from Terminal and use Retry Connection."
            }
        }
    }
}
