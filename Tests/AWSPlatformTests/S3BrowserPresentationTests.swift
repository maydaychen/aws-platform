import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class S3BrowserPresentationTests: XCTestCase {
    func testBreadcrumbAncestorButtonsNavigateToExactPrefixes() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var destinations: [String] = []
        let root = S3BreadcrumbView(bucket: "example", prefix: "a//b/") { destinations.append($0) }
            .environment(\.locale, Locale(identifier: "en"))
        let view = NSHostingView(rootView: root)
        let window = makeWindow(view: view, width: 420, height: 60, dark: false)
        defer { window.close() }
        draw(view)
        let buttons = descendants(view).compactMap { $0 as? NSButton }
            .sorted { $0.convert($0.bounds, to: view).minX < $1.convert($1.bounds, to: view).minX }
        XCTAssertEqual(buttons.count, 3, "Only Root and the two ancestor segments are buttons")
        for (index, button) in buttons.enumerated() { try press(button, in: window, index: index) }
        XCTAssertEqual(destinations, ["", "a/", "a//"])
    }

    func testNativeLoadMoreAndRetryKeepAlreadyLoadedRows() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var calls = 0
        let first = S3ObjectModel(key: "first", size: 1, lastModified: nil, storageClass: nil, isPrefix: false)
        let last = S3ObjectModel(key: "last", size: 2, lastModified: nil, storageClass: nil, isPrefix: false)
        let vm = S3ViewModel(objectLoader: { _, _, token in
            calls += 1
            if token == nil { return .init(objects: [first], nextContinuationToken: "next") }
            if calls == 2 { throw BrowserFailure.failed }
            return .init(objects: [last])
        })
        await vm.loadObjects(bucket: "example")
        let view = NSHostingView(rootView: S3ObjectPaginationFooter(vm: vm, bucket: "example")
            .frame(width: 280, height: 160))
        let window = makeWindow(view: view, width: 280, height: 160, dark: false)
        defer { window.close() }
        for index in 0..<2 {
            draw(view)
            window.recalculateKeyViewLoop()
            let buttons = keyViews(in: view)
            XCTAssertEqual(buttons.count, 1)
            try press(XCTUnwrap(buttons.first), in: window, index: index)
            for _ in 0..<1_000 {
                if !vm.isLoading { break }
                await Task.yield()
            }
            if index == 0 {
                XCTAssertNotNil(vm.objectPageError)
                XCTAssertEqual(vm.objects, [first])
                XCTAssertEqual(vm.nextObjectToken, "next")
            }
        }
        XCTAssertEqual(calls, 3)
        XCTAssertNil(vm.objectPageError)
        XCTAssertEqual(vm.objects, [first, last])
        XCTAssertEqual(vm.selectedObject, first)
        draw(view)
        window.recalculateKeyViewLoop()
        XCTAssertTrue(keyViews(in: view).isEmpty)
    }

    func testPartialFilteredErrorAndCompleteListRenderInBothLanguagesAndWidths() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original = S3TransferFixtures.context()
        let prefix = "中文/" + String(repeating: "long-folder/", count: 5) + "/"
        let context = S3TransferContext(scope: original.scope, bucket: original.bucket,
                                       prefix: prefix, knownRegion: original.knownRegion)
        let items = (0..<8).map { index in
            S3ObjectModel(key: prefix + "file-\(index).json", size: Int64(index * 100),
                          lastModified: nil, storageClass: "STANDARD", isPrefix: false)
        }
        for (language, dark) in [("en", false), ("zh-Hans", true)] {
            for width in [280, 420] {
                for phase in ["partial", "filtered", "error", "complete"] {
                    var calls = 0
                    let vm = S3ViewModel(objectLoader: { _, _, token in
                        calls += 1
                        if token == nil { return .init(objects: items, nextContinuationToken: phase == "complete" ? nil : "next") }
                        throw BrowserFailure.failed
                    })
                    await vm.loadObjects(bucket: context.bucket, prefix: prefix)
                    if phase == "filtered" { vm.objectSearchText = "not-in-loaded-page" }
                    if phase == "error" {
                        vm.loadMoreObjects(bucket: context.bucket)
                        for _ in 0..<1_000 {
                            if !vm.isLoading { break }
                            await Task.yield()
                        }
                        XCTAssertNotNil(vm.objectPageError)
                        XCTAssertEqual(vm.objects.count, 8)
                    }
                    let transfer = S3TransferViewModel(uploader: { _, _ in XCTFail("Rendering must not upload") }, downloader: { _, _, _, _ in })
                    transfer.configure(scope: context.scope)
                    let root = S3ObjectListView(vm: vm, transferVM: transfer, bucketName: context.bucket, transferContext: context)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.locale, Locale(identifier: language))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let view = NSHostingView(rootView: root)
                    let window = makeWindow(view: view, width: width, height: 520, dark: dark)
                    defer { window.close() }
                    draw(view)
                    try await Task.sleep(nanoseconds: 20_000_000)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        .appendingPathComponent(".tmp/s3-browsing/screenshots", isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try png.write(to: output.appendingPathComponent("\(language)-\(width)-\(phase).png"))
                    XCTAssertEqual(view.bounds.width, CGFloat(width))
                    XCTAssertEqual(calls, phase == "error" ? 2 : 1, "Rendering must not fetch more pages")
                    XCTAssertNil(transfer.pendingUpload)
                }
            }
        }
    }

    private func makeWindow(view: NSView, width: Int, height: Int, dark: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.orderBack(nil)
        return window
    }

    private func draw(_ view: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func keyViews(in root: NSView) -> [NSView] {
        var result: [NSView] = []
        var seen = Set<ObjectIdentifier>([ObjectIdentifier(root)])
        var next = root.nextKeyView
        while let view = next, seen.insert(ObjectIdentifier(view)).inserted {
            if view.isDescendant(of: root), !view.isHiddenOrHasHiddenAncestor { result.append(view) }
            next = view.nextKeyView
        }
        return result
    }

    private func press(_ button: NSView, in window: NSWindow, index: Int) throws {
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: index * 2 + 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.001, windowNumber: window.windowNumber,
            context: nil, eventNumber: index * 2 + 2, clickCount: 1, pressure: 0))
        // Queue the release before AppKit starts its local button tracking loop.
        NSApplication.shared.postEvent(up, atStart: true)
        window.sendEvent(down)
        window.sendEvent(up)
    }
}

private enum BrowserFailure: LocalizedError {
    case failed
    var errorDescription: String? { "S3 permission denied. Check `s3:ListAllMyBuckets`, `s3:GetBucketLocation`, and `s3:ListBucket` for this profile." }
}
