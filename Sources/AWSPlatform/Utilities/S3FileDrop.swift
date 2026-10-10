import Foundation
import UniformTypeIdentifiers

@MainActor
enum S3FileDrop {
    static func load(_ providers: [NSItemProvider]) async throws -> URL {
        guard providers.count == 1 else { throw S3TransferError.multipleFiles }
        let provider = providers[0]
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            throw S3TransferError.invalidFile
        }
        let load = FileURLLoad()
        let data: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard load.start(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let progress = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                    if let error { load.finish(.failure(error)) }
                    else if let data { load.finish(.success(data)) }
                    else { load.finish(.failure(S3TransferError.invalidFile)) }
                }
                load.setProgress(progress)
            }
        } onCancel: { load.cancel() }
        try Task.checkCancellation()
        return try fileURL(from: data)
    }

    static func fileURL(from data: Data) throws -> URL {
        guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.query == nil, url.fragment == nil else { throw S3TransferError.invalidFile }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw S3TransferError.invalidFile }
        return url
    }
}

/// NSItemProvider callbacks and task cancellation may race on different threads.
/// The lock protects the continuation and Progress; only one path resumes the task.
private final class FileURLLoad: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var progress: Progress?
    private var cancelled = false

    func start(_ continuation: CheckedContinuation<Data, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.continuation = continuation
        return true
    }

    func setProgress(_ progress: Progress) {
        lock.lock()
        let shouldCancel = cancelled
        if !shouldCancel, continuation != nil { self.progress = progress }
        lock.unlock()
        if shouldCancel { progress.cancel() }
    }

    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        progress = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let pending = continuation
        let active = progress
        continuation = nil
        progress = nil
        lock.unlock()
        active?.cancel()
        pending?.resume(throwing: CancellationError())
    }
}
