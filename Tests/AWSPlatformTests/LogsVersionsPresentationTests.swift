import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class LogsVersionsPresentationTests: XCTestCase {
    func testLogGroupsAndManualEventsFitNarrowPanesInBothLanguages() async throws {
        let name = "/application/" + String(repeating: "long-service-name/", count: 8)
        let group = logsBrowserGroup(name)
        let vm = CloudWatchLogsBrowserViewModel(groupLoader: { _ in [group] }, streamLoader: { _, _ in [
            .init(name: "application/" + String(repeating: "long-stream-name", count: 5), createdAt: nil,
                  firstEventAt: nil, lastEventAt: nil)
        ] }, eventLoader: { query, _ in .init(query: query, events: [
            .init(id: "log", timestamp: query.startTime, ingestionTime: nil, streamName: "application/main",
                  message: String(repeating: "Long message 内容 ", count: 150))
        ], cursor: .init(query: query, nextToken: "more", seenTokens: ["more"], pagesRead: 1)) })
        vm.configure(scope: logsVersionsScope())
        vm.loadIfNeeded(); await vm.waitForLoading()
        XCTAssertNil(vm.selectedGroup)
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", ColorScheme.dark)] {
            try snapshot(CloudWatchLogGroupListView(vm: vm), name: "logs-list-\(language)",
                         width: 280, height: 560, language: language, scheme: scheme)
        }
        vm.selectedGroup = group
        await vm.waitForLoading()
        vm.searchEvents(now: Date(timeIntervalSince1970: 1_700_003_600))
        await vm.waitForLoading()
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", ColorScheme.dark)] {
            try snapshot(CloudWatchLogGroupDetailView(vm: vm), name: "logs-detail-\(language)",
                         width: 480, height: 1_100, language: language, scheme: scheme)
        }
    }

    func testLogPermissionFailureAndEmptyDetailRenderWithoutRawProviderError() async throws {
        let group = logsBrowserGroup()
        let vm = CloudWatchLogsBrowserViewModel(groupLoader: { _ in [group] },
            streamLoader: { _, _ in throw CloudWatchLogsBrowserError.permission },
            eventLoader: { _, _ in throw CloudWatchLogsBrowserError.permission })
        try snapshot(CloudWatchLogGroupDetailView(vm: vm), name: "logs-empty-zh-Hans", width: 480, height: 560,
                     language: "zh-Hans", scheme: .dark)
        vm.configure(scope: logsVersionsScope())
        vm.loadIfNeeded(); await vm.waitForLoading()
        vm.selectedGroup = group; await vm.waitForLoading()
        vm.searchEvents(now: Date(timeIntervalSince1970: 1_700_003_600)); await vm.waitForLoading()
        XCTAssertNotNil(vm.streamError)
        XCTAssertNotNil(vm.eventError)
        try snapshot(CloudWatchLogGroupDetailView(vm: vm), name: "logs-errors-zh-Hans", width: 480, height: 1_100,
                     language: "zh-Hans", scheme: .dark)
    }

    func testVersionsSheetPreservesDeleteMarkersUnknownMetadataAndCostNotice() async throws {
        let target = versionsTarget()
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", ColorScheme.dark)] {
            let vm = S3VersionsViewModel(resolver: { _, _ in target }, loader: { target, _ in
                .init(target: target, versions: [
                    .init(versionID: String(repeating: "long-version-id-", count: 8), kind: .version, isLatest: nil,
                          lastModified: nil, size: 0, eTag: "\"etag\"", storageClass: "STANDARD"),
                    .init(versionID: "deleted-version", kind: .deleteMarker, isLatest: true,
                          lastModified: Date(timeIntervalSince1970: 1_700_000_000), size: nil, eTag: nil, storageClass: nil)
                ], cursor: .init(target: target, marker: .init(key: target.key, versionID: "next"),
                                seenMarkers: [.init(key: target.key, versionID: "next")], pagesRead: 1))
            })
            vm.configure(context: target.context, key: target.key)
            vm.load(); await vm.waitForLoading()
            XCTAssertEqual(vm.versions.count, 2)
            vm.configure(context: target.context, key: target.key)
            vm.load(); await vm.waitForLoading()
            XCTAssertEqual(vm.versions.count, 2)
            try snapshot(S3VersionsView(vm: vm), name: "s3-versions-\(language)", width: 480, height: 850,
                         language: language, scheme: scheme) {
                XCTAssertEqual(vm.versions.count, 2)
                XCTAssertEqual(Set(vm.versions.map(\.kind)), [.version, .deleteMarker])
                XCTAssertTrue(vm.hasMore)
                XCTAssertNil(vm.error)
            }
        }
    }

    private func snapshot<Content: View>(_ content: Content, name: String, width: CGFloat, height: CGFloat,
                                        language: String, scheme: ColorScheme, assertContent: () -> Void = {}) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = content.frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.orderBack(nil)
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded(); view.displayIfNeeded()
        assertContent()
        XCTAssertLessThanOrEqual(view.fittingSize.width, width)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 1, accuracy: 0.01)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/service-submodules/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
}
