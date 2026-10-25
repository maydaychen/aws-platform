import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class S3VersionsLifecycleTests: XCTestCase {
    func testCanonicalEquivalentPrefixByteChangeResetsMountedHistoryAndRejectsLateResults() async throws {
        let original = context(prefix: "caf\u{00e9}/")
        let changed = context(prefix: "cafe\u{0301}/")
        // Swift String equality hides this change; S3 identifies the two prefixes by their bytes.
        XCTAssertEqual(original, changed)
        XCTAssertNotEqual(Data(original.prefix.utf8), Data(changed.prefix.utf8))
        for (from, to) in [(original, changed), (changed, original)] {
            for fail in [false, true] {
                try await assertMountedReset(original: from, changed: to, fail: fail)
            }
        }
    }

    func testScopeChangeResetsMountedHistoryAndRejectsLateResults() async throws {
        let original = context()
        let changed = context(scope: logsVersionsScope(role: "OtherRole"))
        XCTAssertNotEqual(original.scope, changed.scope)
        XCTAssertEqual(Data(original.prefix.utf8), Data(changed.prefix.utf8))
        for fail in [false, true] {
            try await assertMountedReset(original: original, changed: changed, fail: fail)
        }
    }

    func testLeavingMountedObjectListResetsHistoryAndRejectsLateResults() async throws {
        for fail in [false, true] {
            try await assertMountedReset(original: context(), changed: nil, fail: fail)
        }
    }

    private func assertMountedReset(original: S3TransferContext, changed: S3TransferContext?, fail: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        XCTAssertTrue(original.isValid)
        let list = S3ViewModel(bucketLoader: { [] }, detailLoader: { $0 },
                               objectLoader: { _, _, _ in .init(objects: []) })
        let transfer = S3TransferViewModel(uploader: { _, _ in XCTFail("Lifecycle rendering must not upload") },
                                         downloader: { _, _, _, _ in
            XCTFail("Lifecycle rendering must not download")
            return .init()
        })
        transfer.configure(scope: original.scope)
        let probe = S3VersionsLifecycleProbe(fail: fail)
        let versions = S3VersionsViewModel(resolver: { context, key in
            .init(context: context, key: key, region: context.knownRegion ?? context.scope.region)
        }, loader: { target, _ in try await probe.load(target) })
        let view = NSHostingView(rootView: AnyView(S3ObjectListView(vm: list, transferVM: transfer,
            bucketName: original.bucket, transferContext: original, versionsVM: versions)))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.close() }
        settle(window, view)

        let key = original.prefix + "history.txt"
        let target = S3VersionsTarget(context: original, key: key, region: "eu-west-1")
        XCTAssertTrue(target.isValid)
        versions.configure(context: original, key: key)
        versions.searchText = "old-search"
        versions.load()
        await probe.gate.waitForEntry()
        XCTAssertTrue(versions.isLoading)
        XCTAssertEqual(versions.context, original)
        let oldRequest = Task { await versions.waitForLoading() }
        await Task.yield()

        if let changed {
            XCTAssertTrue(changed.isValid)
            // Preserve the view's identity; its own onChange lifecycle must invalidate the request.
            view.rootView = AnyView(S3ObjectListView(vm: list, transferVM: transfer,
                bucketName: changed.bucket, transferContext: changed, versionsVM: versions))
        } else {
            view.rootView = AnyView(Text("Another service"))
        }
        settle(window, view)
        assertReset(versions)

        await probe.gate.open()
        await oldRequest.value
        let cancelled = await probe.wasCancelled
        XCTAssertTrue(cancelled, "Leaving the old browsing context must cancel its pending history request")
        assertReset(versions)
    }

    private func assertReset(_ versions: S3VersionsViewModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(versions.context, file: file, line: line)
        XCTAssertNil(versions.key, file: file, line: line)
        XCTAssertTrue(versions.versions.isEmpty, file: file, line: line)
        XCTAssertFalse(versions.isLoading, file: file, line: line)
        XCTAssertFalse(versions.hasLoaded, file: file, line: line)
        XCTAssertFalse(versions.hasMore, file: file, line: line)
        XCTAssertNil(versions.error, file: file, line: line)
        XCTAssertEqual(versions.searchText, "", file: file, line: line)
    }

    private func context(prefix: String = "reports/", scope: MonitoringScope = logsVersionsScope()) -> S3TransferContext {
        .init(scope: scope, bucket: "example-bucket", prefix: prefix, knownRegion: "eu-west-1")
    }

    private func settle(_ window: NSWindow, _ view: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        view.displayIfNeeded()
    }
}

private actor S3VersionsLifecycleProbe {
    let gate = LogsVersionsGate()
    let fail: Bool
    private(set) var wasCancelled = false

    init(fail: Bool) { self.fail = fail }

    func load(_ target: S3VersionsTarget) async throws -> S3VersionsPage {
        await gate.enter()
        wasCancelled = Task.isCancelled
        if fail { throw S3VersionsError.permission }
        let version = S3ObjectVersion(versionID: "late-version", kind: .version, isLatest: true,
            lastModified: nil, size: 1, eTag: "offline-etag", storageClass: "STANDARD")
        return .init(target: target, versions: [version], cursor: nil)
    }
}
