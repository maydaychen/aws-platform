import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import AWSPlatform

@MainActor
final class S3FileDropTests: XCTestCase {
    func testNativeFileURLRepresentationPreservesSpacesUnicodeAndSpecialCharacters() async throws {
        let url = URL(fileURLWithPath: "/tmp/中文 folder/report #1%.txt")
        let provider = NSItemProvider(object: url as NSURL)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let resolved = try await S3FileDrop.load([provider])
        XCTAssertEqual(resolved, url)
        XCTAssertEqual(try S3FileDrop.fileURL(from: Data(url.absoluteString.utf8)), url)
    }

    func testNonlocalMalformedAndAmbiguousURLsAreRejected() {
        for value in ["https://example.com/file.txt", "file://remote-host/tmp/file.txt", "file:relative.txt",
                      "file:///tmp/file.txt?query=1", "file:///tmp/file.txt#fragment", "file:///tmp/name%00/other.txt", "not a URL"] {
            XCTAssertThrowsError(try S3FileDrop.fileURL(from: Data(value.utf8)), value)
        }
        XCTAssertNoThrow(try S3FileDrop.fileURL(from: Data("file://localhost/tmp/file.txt".utf8)))
        XCTAssertEqual(try? S3FileDrop.fileURL(from: Data("file:///tmp/literal%2500.txt".utf8)).path, "/tmp/literal%00.txt")
    }

    func testMultipleAndUnsupportedProvidersDoNotLoadFileContents() async {
        let text = NSItemProvider(object: "text" as NSString)
        for providers in [[text], [], [text, text]] {
            do {
                _ = try await S3FileDrop.load(providers)
                XCTFail("Unsupported drop must fail")
            } catch {
                XCTAssertEqual(error as? S3TransferError, providers.count == 1 ? .invalidFile : .multipleFiles)
            }
        }
    }

    func testCancelledProviderLoadReturnsBeforeLateCallback() async throws {
        let source = PendingFileURL()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { callback in
            source.register(callback)
            return source.progress
        }
        let task = Task { try await S3FileDrop.load([provider]) }
        for _ in 0..<1000 {
            if source.isLoaded { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(source.isLoaded)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled resolution must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
        source.finish(URL(fileURLWithPath: "/tmp/late.txt").dataRepresentation)
        for _ in 0..<10 { await Task.yield() }
    }
}

private final class PendingFileURL: @unchecked Sendable {
    let progress = Progress(totalUnitCount: 1)
    private let lock = NSLock()
    private var callback: ((Data?, Error?) -> Void)?

    var isLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callback != nil
    }

    func register(_ callback: @escaping (Data?, Error?) -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func finish(_ data: Data) {
        lock.lock()
        let completion = callback
        callback = nil
        lock.unlock()
        completion?(data, nil)
    }
}
