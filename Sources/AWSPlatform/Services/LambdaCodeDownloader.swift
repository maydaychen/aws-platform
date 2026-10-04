import Darwin
import Foundation

struct LambdaCodeDownloader: @unchecked Sendable {
    // Copy the configuration so callers cannot mutate a download after it starts.
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
    }

    func download(from url: URL, to destination: URL, maximumBytes: Int, timeout: TimeInterval) async throws {
        let transfer = LambdaCodeDownload(
            configuration: configuration,
            url: url,
            destination: destination,
            maximumBytes: maximumBytes,
            timeout: timeout
        )
        try await transfer.run()
    }
}

// All mutable state, including delegate callbacks and cancellation, is confined
// to queue. The delegate queue uses the same serial underlying dispatch queue.
private final class LambdaCodeDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "AWSPlatform.LambdaCodeDownload")
    private let configuration: URLSessionConfiguration
    private let url: URL
    private let destination: URL
    private let maximumBytes: Int
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var timer: DispatchSourceTimer?
    private var handle: FileHandle?
    private var receivedBytes = 0
    private var hasValidResponse = false
    private var ownsDestination = false
    private var cancelled = false
    private var finished = false

    init(configuration: URLSessionConfiguration, url: URL, destination: URL, maximumBytes: Int, timeout: TimeInterval) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.url = url
        self.destination = destination
        self.maximumBytes = maximumBytes
        self.timeout = timeout
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                if self.continuation != nil {
                    self.finish(throwing: CancellationError())
                }
            }
        }
    }

    private func start(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
        guard !cancelled else { return finish(throwing: CancellationError()) }
        guard Self.isHTTPS(url) else { return finish(throwing: LambdaCodeError.invalidDownloadURL) }
        guard maximumBytes > 0 else { return finish(throwing: LambdaCodeError.downloadTooLarge) }
        guard timeout.isFinite, timeout > 0 else { return finish(throwing: LambdaCodeError.downloadTimedOut) }
        guard destination.isFileURL else { return finish(throwing: LambdaCodeError.downloadFailed(nil)) }

        // Exclusive creation also rejects an existing file or symbolic link.
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return finish(throwing: LambdaCodeError.downloadFailed(nil)) }
        ownsDestination = true
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.finish(throwing: LambdaCodeError.downloadTimedOut)
        }
        self.timer = timer
        timer.resume()
        let task = session.dataTask(with: url)
        self.task = task
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard !finished else { return completionHandler(.cancel) }
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return finish(throwing: LambdaCodeError.downloadFailed(nil))
        }
        guard Self.isHTTPS(response.url) else {
            completionHandler(.cancel)
            return finish(throwing: LambdaCodeError.invalidDownloadURL)
        }
        guard (200..<300).contains(response.statusCode) else {
            completionHandler(.cancel)
            return finish(throwing: LambdaCodeError.downloadFailed(response.statusCode))
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            return finish(throwing: LambdaCodeError.downloadTooLarge)
        }
        hasValidResponse = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard hasValidResponse, let handle else {
            return finish(throwing: LambdaCodeError.downloadFailed(nil))
        }
        guard data.count <= maximumBytes - receivedBytes else {
            return finish(throwing: LambdaCodeError.downloadTooLarge)
        }
        do {
            try handle.write(contentsOf: data)
            receivedBytes += data.count
        } catch {
            finish(throwing: LambdaCodeError.downloadFailed(nil))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard !finished else { return completionHandler(nil) }
        guard Self.isHTTPS(request.url) else {
            completionHandler(nil)
            return finish(throwing: LambdaCodeError.invalidDownloadURL)
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if cancelled {
            finish(throwing: CancellationError())
        } else if (error as? URLError)?.code == .timedOut {
            finish(throwing: LambdaCodeError.downloadTimedOut)
        } else if error != nil || !hasValidResponse {
            // URLSession errors can embed the signed download URL. Never expose them.
            finish(throwing: LambdaCodeError.downloadFailed(nil))
        } else {
            finish(throwing: nil)
        }
    }

    private func finish(throwing error: Error?) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        var finalError = error
        do {
            try handle?.close()
        } catch {
            if finalError == nil { finalError = LambdaCodeError.downloadFailed(nil) }
        }
        handle = nil
        if finalError != nil, ownsDestination {
            try? FileManager.default.removeItem(at: destination)
        }
        let continuation = self.continuation
        self.continuation = nil
        if let finalError {
            continuation?.resume(throwing: finalError)
        } else {
            continuation?.resume()
        }
    }

    private static func isHTTPS(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
    }
}
