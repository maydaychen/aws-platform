import Darwin
import Foundation
import XCTest
@testable import AWSPlatform

final class AWSCLIHTTPClientTests: XCTestCase {
    private let metadataURL = URL(string: "https://awscli.amazonaws.com/v2/version.txt")!
    private let packageURL = URL(string: "https://awscli.amazonaws.com/AWSCLIV2-2.38.5.pkg")!

    func testAllowlistRejectsCredentialsQueriesAlternateHostsAndUnversionedInstallers() {
        for url in [metadataURL, packageURL, URL(string: "https://formulae.brew.sh/api/formula/awscli.json")!] {
            XCTAssertTrue(AWSCLIHTTPClient.allows(url))
        }
        for value in ["http://awscli.amazonaws.com/v2/version.txt", "https://awscli.amazonaws.com.evil.invalid/v2/version.txt",
                      "https://user@awscli.amazonaws.com/v2/version.txt", "https://awscli.amazonaws.com:443/v2/version.txt",
                      "https://awscli.amazonaws.com/v2/version.txt?token=secret", "https://awscli.amazonaws.com/v2/version.txt#fragment",
                      "https://awscli.amazonaws.com/AWSCLIV2.pkg", "https://awscli.amazonaws.com/AWSCLIV2-1.2.3.pkg",
                      "https://awscli.amazonaws.com/AWSCLIV2-2.38.5.zip", "https://formulae.brew.sh/api/formula/other.json"] {
            XCTAssertFalse(AWSCLIHTTPClient.allows(URL(string: value)!), value)
        }
    }

    func testMetadataAndCatalogUseInjectedSessionWithoutRealNetwork() async throws {
        let fixture = makeFixture(.init(chunks: [Data("2.38.".utf8), Data("5\n".utf8)]))
        defer { fixture.remove() }
        let result = try await fixture.client.data(from: metadataURL, maximumBytes: 1024)
        XCTAssertEqual(result, Data("2.38.5\n".utf8))
        let version = try await AWSCLIVersionCatalog(client: fixture.client).latest(for: .officialPackage)
        XCTAssertEqual(version, AWSCLIVersion("2.38.5"))
    }

    func testRedirectCannotChangeHostProtocolOrEvenAnotherAllowlistedResource() {
        XCTAssertTrue(AWSCLIHTTPClient.allowsRedirect(from: metadataURL, to: metadataURL))
        for target in [packageURL, URL(string: "https://formulae.brew.sh/api/formula/awscli.json")!,
                       URL(string: "https://untrusted.invalid/v2/version.txt")!,
                       URL(string: "http://awscli.amazonaws.com/v2/version.txt")!] {
            XCTAssertFalse(AWSCLIHTTPClient.allowsRedirect(from: metadataURL, to: target))
        }
    }

    func testUnknownLengthResponseCannotExceedByteBudget() async throws {
        let fixture = makeFixture(.init(chunks: [Data(repeating: 1, count: 6), Data(repeating: 2, count: 6)]))
        defer { fixture.remove() }
        do {
            _ = try await fixture.client.data(from: metadataURL, maximumBytes: 10)
            XCTFail("Expected response limit")
        } catch { XCTAssertEqual(error as? AWSCLIUpdateError, .downloadFailed) }
    }

    func testErrorStatusDeclaredOversizeAndTransportTimeoutAreSanitized() async throws {
        for scenario in [CLIHTTPScenario(status: 403, chunks: [Data("private-body".utf8)]),
                         CLIHTTPScenario(headers: ["Content-Length": "2048"]),
                         CLIHTTPScenario(error: URLError(.timedOut))] {
            let fixture = makeFixture(scenario)
            defer { fixture.remove() }
            do {
                _ = try await fixture.client.data(from: metadataURL, maximumBytes: 1024)
                XCTFail("Expected bounded failure")
            } catch {
                XCTAssertEqual(error as? AWSCLIUpdateError, .downloadFailed)
                XCTAssertFalse(error.localizedDescription.contains("private-body"))
            }
        }
    }

    func testStreamingDownloadCreatesPrivateFileAndLeavesExistingDestinationUntouched() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("installer.pkg")
        let fixture = makeFixture(.init(chunks: [Data(repeating: 1, count: 2048), Data(repeating: 2, count: 2048)]))
        defer { fixture.remove() }
        try await fixture.client.download(from: packageURL, to: file, maximumBytes: 8192)
        let contents = try Data(contentsOf: file)
        XCTAssertEqual(contents.count, 4096)
        XCTAssertEqual(contents.first, 1)
        XCTAssertEqual(contents.last, 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        do {
            try await fixture.client.download(from: packageURL, to: file, maximumBytes: 8192)
            XCTFail("Existing file must not be overwritten")
        } catch { XCTAssertEqual(error as? AWSCLIUpdateError, .downloadFailed) }
        XCTAssertEqual(try Data(contentsOf: file), contents)
    }

    func testFailedDownloadRemovesOnlyItsPartialFileAndRejectsSymlink() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("installer.pkg")
        let fixture = makeFixture(.init(chunks: [Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)]))
        defer { fixture.remove() }
        do {
            try await fixture.client.download(from: packageURL, to: file, maximumBytes: 48)
            XCTFail("Expected size rejection")
        } catch { XCTAssertEqual(error as? AWSCLIUpdateError, .downloadFailed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let original = directory.appendingPathComponent("original")
        try Data("preserved".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
        do {
            try await fixture.client.download(from: packageURL, to: file, maximumBytes: 1024)
            XCTFail("Symlink must be rejected")
        } catch { XCTAssertEqual(error as? AWSCLIUpdateError, .downloadFailed) }
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "preserved")
    }

    func testCancellationStopsRequestAndRemovesPartialDownload() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("installer.pkg")
        let fixture = makeFixture(.init(chunks: [Data(repeating: 1, count: 16)], stalls: true))
        defer { fixture.remove() }
        let packageURL = packageURL
        let task = Task { try await fixture.client.download(from: packageURL, to: file, maximumBytes: 1024) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !CLIHTTPProtocol.registry.started(fixture.id), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(CLIHTTPProtocol.registry.started(fixture.id))
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testInvalidURLIsRejectedBeforeAnyRequest() async throws {
        let fixture = makeFixture(.init(chunks: [Data("must-not-run".utf8)]))
        defer { fixture.remove() }
        do {
            _ = try await fixture.client.data(from: URL(string: "https://untrusted.invalid/version.txt")!, maximumBytes: 1024)
            XCTFail("Expected URL rejection")
        } catch { XCTAssertEqual(error as? AWSCLIUpdateError, .downloadFailed) }
        XCTAssertFalse(CLIHTTPProtocol.registry.started(fixture.id))
    }

    func testCleanupRestoresAReplacementThatArrivedBeforeAtomicClaim() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("partial.pkg")
        let retained = directory.appendingPathComponent("original-partial.pkg")
        let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertGreaterThanOrEqual(parent, 0)
        defer { Darwin.close(descriptor); Darwin.close(parent) }
        AWSCLIHTTPFile.discard(descriptor: descriptor, parent: parent, name: file.lastPathComponent) {
            XCTAssertEqual(Darwin.rename(file.path, retained.path), 0)
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("preserved-replacement".utf8)))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "preserved-replacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix(".awsplatform-download-cleanup-") }))
    }

    private func makeFixture(_ scenario: CLIHTTPScenario) -> CLIHTTPFixture {
        let id = UUID().uuidString
        CLIHTTPProtocol.registry.register(scenario, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CLIHTTPProtocol.self]
        configuration.httpAdditionalHeaders = ["X-AWSPlatform-Fixture": id]
        return CLIHTTPFixture(client: AWSCLIHTTPClient(configuration: configuration), id: id)
    }

    private func makeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/aws-cli-update/http/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct CLIHTTPFixture: Sendable {
    let client: AWSCLIHTTPClient
    let id: String
    func remove() { CLIHTTPProtocol.registry.remove(id) }
}

private struct CLIHTTPScenario: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var chunks: [Data] = []
    var stalls = false
    var error: URLError?
}

private final class CLIHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var scenarios: [String: CLIHTTPScenario] = [:]
    private var requests = Set<String>()
    func register(_ scenario: CLIHTTPScenario, id: String) {
        lock.lock(); defer { lock.unlock() }
        scenarios[id] = scenario
    }
    func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        scenarios.removeValue(forKey: id)
        requests.remove(id)
    }
    func scenario(_ id: String) -> CLIHTTPScenario? {
        lock.lock(); defer { lock.unlock() }
        requests.insert(id)
        return scenarios[id]
    }
    func started(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return requests.contains(id)
    }
}

private final class CLIHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let registry = CLIHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-AWSPlatform-Fixture"),
              let scenario = Self.registry.scenario(id), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if let error = scenario.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: scenario.status, httpVersion: "HTTP/1.1", headerFields: scenario.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in scenario.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if !scenario.stalls { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
