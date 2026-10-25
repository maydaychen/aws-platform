import Darwin
import Foundation

/// Only AWS's versioned installer and the two fixed version documents are accepted.
struct AWSCLIHTTPClient: @unchecked Sendable {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }

    func data(from url: URL, maximumBytes: Int) async throws -> Data {
        try await perform(url, maximumBytes: maximumBytes, destination: nil)
    }

    func download(from url: URL, to destination: URL, maximumBytes: Int) async throws {
        _ = try await perform(url, maximumBytes: maximumBytes, destination: destination)
    }

    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return false }
        switch url.host {
        case "formulae.brew.sh": return url.path == "/api/formula/awscli.json"
        case "awscli.amazonaws.com":
            if url.path == "/v2/version.txt" { return true }
            guard url.path.hasPrefix("/AWSCLIV2-"), url.path.hasSuffix(".pkg") else { return false }
            let version = String(url.path.dropFirst("/AWSCLIV2-".count).dropLast(".pkg".count))
            guard let parsed = AWSCLIVersion(version), parsed.major == 2 else { return false }
            return version == parsed.description
        default: return false
        }
    }

    static func allowsRedirect(from original: URL, to target: URL) -> Bool {
        allows(target) && target.host == original.host && target.path == original.path
    }

    private func perform(_ url: URL, maximumBytes: Int, destination: URL?) async throws -> Data {
        guard Self.allows(url), maximumBytes > 0 else { throw AWSCLIUpdateError.downloadFailed }
        try Task.checkCancellation()
        let operation = try AWSCLIHTTPRequest(url: url, maximumBytes: maximumBytes, destination: destination)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

private final class AWSCLIHTTPRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let maximumBytes: Int
    private let destinationName: String?
    private var parentDescriptor: Int32 = -1
    private var descriptor: Int32 = -1
    private var bytesReceived = 0
    private var data = Data()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, Error>?
    private var failure: Error?
    private var cancelled = false
    private var finished = false

    init(url: URL, maximumBytes: Int, destination: URL?) throws {
        self.url = url
        self.maximumBytes = maximumBytes
        self.destinationName = destination?.lastPathComponent
        super.init()
        if let destination {
            guard destination.isFileURL, !destination.lastPathComponent.isEmpty,
                  ![".", "..", "/"].contains(destination.lastPathComponent) else {
                throw AWSCLIUpdateError.downloadFailed
            }
            parentDescriptor = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parentDescriptor >= 0 else { throw AWSCLIUpdateError.downloadFailed }
            descriptor = openat(parentDescriptor, destination.lastPathComponent, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else {
                Darwin.close(parentDescriptor)
                parentDescriptor = -1
                throw AWSCLIUpdateError.downloadFailed
            }
        }
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
        if parentDescriptor >= 0 { Darwin.close(parentDescriptor) }
    }

    func start(configuration: URLSessionConfiguration, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        self.continuation = continuation
        let sessionConfiguration = configuration.copy() as! URLSessionConfiguration
        sessionConfiguration.timeoutIntervalForRequest = 30
        sessionConfiguration.timeoutIntervalForResource = destinationName == nil ? 60 : 300
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: queue)
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        self.task = task
        let alreadyCancelled = cancelled
        lock.unlock()
        task.resume()
        if alreadyCancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url, AWSCLIHTTPClient.allowsRedirect(from: url, to: target) else {
            failure = AWSCLIUpdateError.downloadFailed
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url.map(AWSCLIHTTPClient.allows) == true,
              response.expectedContentLength <= Int64(maximumBytes) else {
            failure = AWSCLIUpdateError.downloadFailed
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard failure == nil, chunk.count <= maximumBytes - bytesReceived else {
            failure = AWSCLIUpdateError.downloadFailed
            dataTask.cancel()
            return
        }
        bytesReceived += chunk.count
        if descriptor < 0 {
            data.append(chunk)
            return
        }
        let success = chunk.withUnsafeBytes { buffer -> Bool in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count > 0 { written += count }
                else if count < 0, errno == EINTR { continue }
                else { return false }
            }
            return true
        }
        if !success {
            failure = AWSCLIUpdateError.downloadFailed
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let resultError: Error? = cancelled ? CancellationError() : (failure ?? error.map { _ in AWSCLIUpdateError.downloadFailed })
        let continuation = continuation
        self.continuation = nil
        self.task = nil
        lock.unlock()
        var finalError = resultError
        if descriptor >= 0 {
            if finalError == nil, fsync(descriptor) != 0 { finalError = AWSCLIUpdateError.downloadFailed }
            if finalError != nil { removePartialFile() }
            Darwin.close(descriptor)
            descriptor = -1
        }
        if parentDescriptor >= 0 {
            Darwin.close(parentDescriptor)
            parentDescriptor = -1
        }
        session.finishTasksAndInvalidate()
        if let finalError { continuation?.resume(throwing: finalError) }
        else { continuation?.resume(returning: data) }
    }

    private func removePartialFile() {
        guard let destinationName else { return }
        AWSCLIHTTPFile.discard(descriptor: descriptor, parent: parentDescriptor, name: destinationName)
    }
}

enum AWSCLIHTTPFile {
    /// Atomically claim the directory entry before inspecting it. A replacement is
    /// restored without overwriting a concurrently created destination.
    static func discard(
        descriptor: Int32, parent: Int32, name: String,
        beforeClaim: () -> Void = {}
    ) {
        let claimName = ".awsplatform-download-cleanup-\(UUID().uuidString)"
        guard mkdirat(parent, claimName, 0o700) == 0 else { return }
        let claim = openat(parent, claimName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard claim >= 0 else { _ = unlinkat(parent, claimName, AT_REMOVEDIR); return }
        defer {
            Darwin.close(claim)
            // A replacement that could not be restored is intentionally preserved.
            _ = unlinkat(parent, claimName, AT_REMOVEDIR)
        }
        beforeClaim()
        guard renameatx_np(parent, name, claim, "partial", UInt32(RENAME_EXCL)) == 0 else { return }
        var opened = stat()
        var claimed = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(claim, "partial", &claimed, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_dev == claimed.st_dev, opened.st_ino == claimed.st_ino,
              claimed.st_uid == getuid(), claimed.st_nlink == 1,
              claimed.st_mode & S_IFMT == S_IFREG else {
            _ = renameatx_np(claim, "partial", parent, name, UInt32(RENAME_EXCL))
            return
        }
        _ = unlinkat(claim, "partial", 0)
    }
}
