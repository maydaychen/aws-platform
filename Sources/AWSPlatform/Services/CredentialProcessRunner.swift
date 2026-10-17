import Darwin
import Foundation

/// Captures the small credential response in memory without waiting for pipe EOF
/// or child termination on a cooperative executor thread.
enum CredentialProcessRunner {
    enum Failure: Error, Equatable {
        case unavailable, timedOut, outputLimit
    }

    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration = .seconds(30),
        terminationGrace: Duration = .seconds(1),
        outputLimit: Int = 64 * 1024
    ) async throws -> Data {
        guard timeout > .zero, terminationGrace >= .zero, outputLimit > 0 else {
            throw Failure.unavailable
        }
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw Failure.unavailable
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        do {
            try Task.checkCancellation()
            do { try process.run() } catch { throw Failure.unavailable }
            // The child owns its duplicated write descriptor. Keeping ours would
            // prevent EOF even after the child and all its descendants exit.
            try pipe.fileHandleForWriting.close()
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            var reachedEOF = false
            while true {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw Failure.timedOut }
                if !reachedEOF {
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(descriptor, $0.baseAddress, $0.count)
                    }
                    if count > 0 {
                        guard count <= outputLimit - output.count else { throw Failure.outputLimit }
                        output.append(contentsOf: buffer.prefix(count))
                        continue
                    } else if count == 0 {
                        reachedEOF = true
                    } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        throw Failure.unavailable
                    }
                }
                if reachedEOF, !process.isRunning {
                    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                        throw Failure.unavailable
                    }
                    return output
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            // Cancellation must not skip cleanup. Only this Process's direct child
            // receives signals; closing the pipe also handles inherited writers.
            await Task.detached {
                await stop(process, grace: terminationGrace)
            }.value
            throw error
        }
    }

    private static func stop(_ process: Process, grace: Duration) async {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGTERM)
        let termDeadline = ContinuousClock.now.advanced(by: grace)
        while process.isRunning, ContinuousClock.now < termDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        // Foundation reaps its own Process child. Never wait indefinitely even if
        // the operating system cannot finish termination immediately.
        let killDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while process.isRunning, ContinuousClock.now < killDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
