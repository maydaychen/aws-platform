import Darwin
import Foundation

struct AWSCLIInstallCommand: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
}

struct AWSCLIInstallProcessResult: Sendable {
    let status: Int32
    let output: Data
    let outputWasTruncated: Bool
}

/// Installation owns its lifetime after launch. Caller cancellation must not release
/// the application's maintenance lease while an installer or brew child still runs.
enum AWSCLIInstallProcess {
    static func run(_ command: AWSCLIInstallCommand, outputLimit: Int = 64 * 1024) async throws -> AWSCLIInstallProcessResult {
        try Task.checkCancellation()
        guard outputLimit > 0 else { throw AWSCLIUpdateError.updateFailed }
        return try await Task.detached(priority: .utility) {
            try await execute(command, outputLimit: outputLimit)
        }.value
    }

    private static func execute(_ command: AWSCLIInstallCommand, outputLimit: Int) async throws -> AWSCLIInstallProcessResult {
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw AWSCLIUpdateError.updateFailed
        }
        do { try process.run() } catch { throw AWSCLIUpdateError.updateFailed }
        try? pipe.fileHandleForWriting.close()
        var output = Data()
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: 8192)
        func drain() {
            // A bounded batch prevents a noisy child from starving process observation.
            for _ in 0..<32 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                guard count > 0 else { return }
                let kept = min(count, max(0, outputLimit - output.count))
                if kept > 0 { output.append(contentsOf: buffer.prefix(kept)) }
                if kept < count { truncated = true }
            }
        }
        while process.isRunning {
            drain()
            // This detached task is deliberately not cancelled by the requesting view.
            try? await Task.sleep(for: .milliseconds(20))
        }
        drain()
        return AWSCLIInstallProcessResult(
            status: process.terminationReason == .exit ? process.terminationStatus : -1,
            output: output, outputWasTruncated: truncated
        )
    }

    static func environment(homebrew: Bool = false, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] {
            if let value = base[key] { environment[key] = value }
        }
        if homebrew {
            environment["HOMEBREW_NO_ANALYTICS"] = "1"
            environment["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"] = "1"
            environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
            environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        }
        return environment
    }
}
