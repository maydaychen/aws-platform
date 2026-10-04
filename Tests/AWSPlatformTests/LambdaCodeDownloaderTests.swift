import XCTest
@testable import AWSPlatform

@MainActor
final class LambdaCodeDownloaderTests: XCTestCase {
    func testDownloadsMultipleChunksUpToExactLimit() async throws {
        let fixture = try DownloadFixture(.init(headers: ["Content-Length": "8"], chunks: [Data("abcd".utf8), Data("efgh".utf8)]))
        defer { fixture.cleanup() }
        try await fixture.download(maximumBytes: 8)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("abcdefgh".utf8))
    }

    func testDownloadsResponseWithUnknownLength() async throws {
        let fixture = try DownloadFixture(.init(chunks: [Data("source".utf8)]))
        defer { fixture.cleanup() }
        try await fixture.download(maximumBytes: 8)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("source".utf8))
    }

    func testRejectsDeclaredLengthAboveLimitBeforeReceivingBody() async throws {
        let fixture = try DownloadFixture(.init(headers: ["Content-Length": "100"], completes: false))
        defer { fixture.cleanup() }
        do {
            try await fixture.download(maximumBytes: 8)
            XCTFail("Expected declared size rejection")
        } catch {
            guard case LambdaCodeError.downloadTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        await waitUntil { fixture.scenario.stopped }
    }

    func testRejectsActualBytesAboveLimitDespiteSmallerDeclaredLength() async throws {
        let fixture = try DownloadFixture(.init(headers: ["Content-Length": "1"], chunks: [Data("abcd".utf8), Data("efghi".utf8)]))
        defer { fixture.cleanup() }
        do {
            try await fixture.download(maximumBytes: 8)
            XCTFail("Expected streamed size rejection")
        } catch {
            guard case LambdaCodeError.downloadTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testRejectsUnknownLengthStreamAboveLimit() async throws {
        let fixture = try DownloadFixture(.init(chunks: [Data(repeating: 1, count: 9)]))
        defer { fixture.cleanup() }
        do {
            try await fixture.download(maximumBytes: 8)
            XCTFail("Expected streamed size rejection")
        } catch {
            guard case LambdaCodeError.downloadTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testRejectsHTTPFailureWithOnlyStatusCode() async throws {
        let fixture = try DownloadFixture(.init(status: 403, chunks: [Data("private response".utf8)]))
        defer { fixture.cleanup() }
        do {
            try await fixture.download()
            XCTFail("Expected HTTP rejection")
        } catch {
            guard case LambdaCodeError.downloadFailed(let status) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(status, 403)
            XCTAssertFalse(error.localizedDescription.contains("private-signature"))
            XCTAssertFalse(error.localizedDescription.contains("private response"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testSanitizesNetworkErrorContainingSignedURL() async throws {
        let fixture = try DownloadFixture(.init(failure: URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://download.invalid/?signature=private-signature"])))
        defer { fixture.cleanup() }
        do {
            try await fixture.download()
            XCTFail("Expected network error")
        } catch {
            guard case LambdaCodeError.downloadFailed(let status) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertNil(status)
            XCTAssertFalse(error.localizedDescription.contains("private-signature"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testTotalTimeoutCancelsTransferAndRemovesPartialFile() async throws {
        let fixture = try DownloadFixture(.init(chunks: [Data("partial".utf8)], completes: false))
        defer { fixture.cleanup() }
        do {
            try await fixture.download(timeout: 0.1)
            XCTFail("Expected timeout")
        } catch {
            guard case LambdaCodeError.downloadTimedOut = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        await waitUntil { fixture.scenario.stopped }
    }

    func testNetworkTimeoutUsesSanitizedTimeoutError() async throws {
        let fixture = try DownloadFixture(.init(failure: URLError(.timedOut)))
        defer { fixture.cleanup() }
        do {
            try await fixture.download()
            XCTFail("Expected timeout")
        } catch {
            guard case LambdaCodeError.downloadTimedOut = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testCancellationStopsTransferAndRemovesPartialFile() async throws {
        let fixture = try DownloadFixture(.init(chunks: [Data("partial".utf8)], completes: false))
        defer { fixture.cleanup() }
        let transfer = Task { try await fixture.download() }
        await waitUntil { (try? Data(contentsOf: fixture.destination)) == Data("partial".utf8) }
        transfer.cancel()
        do {
            try await transfer.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        await waitUntil { fixture.scenario.stopped }
    }

    func testCancellationBeforeStartDoesNotCreateFileOrRequest() async throws {
        let fixture = try DownloadFixture(.init(completes: false))
        defer { fixture.cleanup() }
        let transfer = Task { try await fixture.download() }
        transfer.cancel()
        do {
            try await transfer.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertFalse(fixture.scenario.started)
    }

    func testRejectsInsecureURLBeforeStartingRequest() async throws {
        let fixture = try DownloadFixture(.init())
        defer { fixture.cleanup() }
        do {
            try await fixture.downloader.download(from: URL(string: "http://download.invalid/archive.zip")!, to: fixture.destination, maximumBytes: 16, timeout: 1)
            XCTFail("Expected insecure URL rejection")
        } catch {
            guard case LambdaCodeError.invalidDownloadURL = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertFalse(fixture.scenario.started)
    }

    func testRejectsRedirectToInsecureURL() async throws {
        let fixture = try DownloadFixture(.init(redirect: URL(string: "http://download.invalid/archive.zip")!))
        defer { fixture.cleanup() }
        do {
            try await fixture.download()
            XCTFail("Expected insecure redirect rejection")
        } catch {
            guard case LambdaCodeError.invalidDownloadURL = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testFollowsHTTPSRedirectAndAppliesLimitToFinalResponse() async throws {
        let target = try DownloadFixture(.init(chunks: [Data("redirected".utf8)]))
        defer { target.cleanup() }
        let fixture = try DownloadFixture(.init(redirect: target.url))
        defer { fixture.cleanup() }
        try await fixture.download()
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("redirected".utf8))
        XCTAssertTrue(target.scenario.started)
    }

    func testInvalidLimitsDoNotCreateAFileOrStartNetwork() async throws {
        let fixture = try DownloadFixture(.init())
        defer { fixture.cleanup() }
        do {
            try await fixture.download(maximumBytes: 0)
            XCTFail("Expected invalid size limit rejection")
        } catch {
            guard case LambdaCodeError.downloadTooLarge = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            try await fixture.download(timeout: 0)
            XCTFail("Expected invalid timeout rejection")
        } catch {
            guard case LambdaCodeError.downloadTimedOut = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertFalse(fixture.scenario.started)
    }

    func testExistingDestinationIsNeverOverwrittenOrDeleted() async throws {
        let fixture = try DownloadFixture(.init(chunks: [Data("replacement".utf8)]))
        defer { fixture.cleanup() }
        try Data("existing".utf8).write(to: fixture.destination)
        do {
            try await fixture.download()
            XCTFail("Expected exclusive creation failure")
        } catch {
            guard case LambdaCodeError.downloadFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.destination), Data("existing".utf8))
        XCTAssertFalse(fixture.scenario.started)
    }

    func testPreviewPipelineRemovesTemporaryDirectoryAfterSuccess() async throws {
        let emptyZIP = Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: 0, count: 18))
        let fixture = try DownloadFixture(.init(chunks: [emptyZIP]))
        defer { fixture.cleanup() }
        let preview = LambdaCodePreview(downloader: fixture.downloader, temporaryDirectory: fixture.root)

        let files = try await preview.load(from: fixture.url.absoluteString)

        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
    }

    func testPreviewPipelineRemovesTemporaryDirectoryAfterInvalidZIP() async throws {
        let fixture = try DownloadFixture(.init(chunks: [Data("not a ZIP".utf8)]))
        defer { fixture.cleanup() }
        let preview = LambdaCodePreview(downloader: fixture.downloader, temporaryDirectory: fixture.root)

        do {
            _ = try await preview.load(from: fixture.url.absoluteString)
            XCTFail("Expected invalid ZIP rejection")
        } catch {
            guard case LambdaCodeError.invalidArchive = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
    }

    func testPreviewPipelineRemovesTemporaryDirectoryAfterDownloadError() async throws {
        let fixture = try DownloadFixture(.init(status: 403))
        defer { fixture.cleanup() }
        let preview = LambdaCodePreview(downloader: fixture.downloader, temporaryDirectory: fixture.root)

        do {
            _ = try await preview.load(from: fixture.url.absoluteString)
            XCTFail("Expected HTTP failure")
        } catch {
            XCTAssertEqual(error as? LambdaCodeError, .downloadFailed(403))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
    }

    func testPreviewPipelineRemovesTemporaryDirectoryAfterCancellation() async throws {
        let fixture = try DownloadFixture(.init(chunks: [Data("partial".utf8)], completes: false))
        defer { fixture.cleanup() }
        let preview = LambdaCodePreview(downloader: fixture.downloader, temporaryDirectory: fixture.root)
        let transfer = Task { try await preview.load(from: fixture.url.absoluteString) }
        await waitUntil { fixture.scenario.started }
        let directories = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertEqual(directories.count, 1)
        XCTAssertTrue(directories.first?.hasPrefix("AWSPlatformLambdaCode-") == true)
        transfer.cancel()

        do {
            _ = try await transfer.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
        await waitUntil { fixture.scenario.stopped }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for download state", file: file, line: line)
    }
}

private struct DownloadFixture: Sendable {
    let root: URL
    let url: URL
    let destination: URL
    let scenario: DownloadScenario
    let downloader: LambdaCodeDownloader

    init(_ scenario: DownloadScenario) throws {
        let identifier = UUID().uuidString.lowercased()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lambda-download-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = URL(string: "https://\(identifier).invalid/archive.zip?signature=private-signature")!
        destination = root.appendingPathComponent("archive.zip")
        self.scenario = scenario
        DownloadURLProtocol.registry.register(scenario, host: url.host!)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadURLProtocol.self]
        downloader = LambdaCodeDownloader(configuration: configuration)
    }

    func download(maximumBytes: Int = 32, timeout: TimeInterval = 2) async throws {
        try await downloader.download(from: url, to: destination, maximumBytes: maximumBytes, timeout: timeout)
    }

    func cleanup() {
        DownloadURLProtocol.registry.remove(host: url.host!)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class DownloadScenario: @unchecked Sendable {
    let status: Int
    let headers: [String: String]
    let chunks: [Data]
    let completes: Bool
    let failure: URLError?
    let redirect: URL?
    private let lock = NSLock()
    private var didStart = false
    private var didStop = false

    init(status: Int = 200, headers: [String: String] = [:], chunks: [Data] = [], completes: Bool = true, failure: URLError? = nil, redirect: URL? = nil) {
        self.status = status
        self.headers = headers
        self.chunks = chunks
        self.completes = completes
        self.failure = failure
        self.redirect = redirect
    }

    var started: Bool { lock.withLock { didStart } }
    var stopped: Bool { lock.withLock { didStop } }
    func markStarted() { lock.withLock { didStart = true } }
    func markStopped() { lock.withLock { didStop = true } }
}

private final class DownloadScenarioRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: DownloadScenario] = [:]
    func register(_ scenario: DownloadScenario, host: String) { lock.withLock { entries[host] = scenario } }
    func scenario(host: String) -> DownloadScenario? { lock.withLock { entries[host] } }
    func remove(host: String) { _ = lock.withLock { entries.removeValue(forKey: host) } }
}

private final class DownloadURLProtocol: URLProtocol, @unchecked Sendable {
    static let registry = DownloadScenarioRegistry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let scenario = Self.registry.scenario(host: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        scenario.markStarted()
        if let failure = scenario.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        if let redirect = scenario.redirect {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": redirect.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            return
        }
        // Without an explicit type CFNetwork buffers small, unfinished mock
        // responses for MIME sniffing before forwarding headers or body.
        let headers = ["Content-Type": "application/zip"].merging(scenario.headers) { _, value in value }
        let response = HTTPURLResponse(url: url, statusCode: scenario.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in scenario.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if scenario.completes { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        if let host = request.url?.host { Self.registry.scenario(host: host)?.markStopped() }
    }
}
