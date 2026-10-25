import AppKit
import SwiftUI
import Vision
import XCTest
@testable import AWSPlatform

@MainActor
final class EC2SecurityRulesPresentationTests: XCTestCase {
    func testCombinedRulesKeepBothDirectionsAndGroupOwnershipAtNarrowAndWideWidths() async throws {
        let groups = EC2SecurityRulesFixture.longGroups
        let variants: [(String, ColorScheme, CGFloat)] = [
            ("en", .light, 480), ("zh-Hans", .dark, 480),
            ("en", .dark, 1_200), ("zh-Hans", .light, 1_200)
        ]
        for (language, scheme, width) in variants {
            let locale = Locale(identifier: language)
            let mounted = mount(ScrollView { EC2SecurityRulesView(groups: groups).padding() },
                                width: width, height: 1_500, language: language, scheme: scheme)
            defer { mounted.window.close() }
            let name = "rules-\(language)-\(scheme == .dark ? "dark" : "light")-\(Int(width))"
            let rendered = try renderedText(in: mounted, language: language, name: name)
            if language == "zh-Hans" {
                XCTAssertTrue(rendered.contains { normalized($0.value) == "安全组" && $0.bounds.minY > 0.9 },
                              "The top security groups heading must use the Chinese translation")
            }
            for key in ["Inbound rules", "Outbound rules", "Source", "Destination"] {
                XCTAssertTrue(contains(L10n.text(key, locale: locale), in: rendered), "Missing rendered \(key)")
            }
            XCTAssertTrue(contains(L10n.format("%@ rules", "3", locale: locale), in: rendered))
            XCTAssertTrue(contains(L10n.format("%@ rule", "1", locale: locale), in: rendered))
            XCTAssertFalse(contains(L10n.text("No inbound rules returned.", locale: locale), in: rendered))
            // Selectable data fields expose native AppKit AX values even in an offscreen window.
            let text = values(in: mounted.view)
            XCTAssertTrue(text.contains(groups[0].groupId))
            XCTAssertTrue(text.contains(groups[1].groupId))
            XCTAssertTrue(text.contains(try XCTUnwrap(groups[0].name)))
            XCTAssertTrue(text.contains(groups[0].inboundRules[0].source))
            XCTAssertTrue(text.contains(try XCTUnwrap(groups[0].inboundRules[0].description)))

            if width == 480 {
                let tables = descendants(mounted.view).compactMap { $0 as? NSScrollView }.filter {
                    guard let document = $0.documentView else { return false }
                    return document.frame.width > $0.contentView.bounds.width + 100
                }
                XCTAssertEqual(tables.count, 2, "Each direction must retain its own horizontal table scroll area")
                for table in tables {
                    // Reveal the ownership header completely rather than leaving its first glyph clipped.
                    table.contentView.scroll(to: NSPoint(x: 380, y: table.contentView.bounds.origin.y))
                    table.reflectScrolledClipView(table.contentView)
                    XCTAssertGreaterThan(table.contentView.bounds.origin.x, 0)
                }
                let ownership = try renderedText(in: mounted, language: language, name: name + "-ownership-columns")
                XCTAssertTrue(contains(L10n.text("Security group", locale: locale), in: ownership))
            } else {
                XCTAssertTrue(contains(L10n.text("Security group", locale: locale), in: rendered))
            }
            try writeEvidence("Actual EC2SecurityRulesView: rendered inbound=3/outbound=1 headers and counts; native AX retained both SG IDs, long name, IPv6 source and full description. Width=\(Int(width)) pt.\n",
                              name: name + "-content.txt")
        }
    }

    func testEmptyRulesShowBothDirectionEmptyStatesAndKeepUnnamedGroupMetadata() async throws {
        let group = EC2SecurityRulesFixture.group("sg-empty-without-name", name: nil, inbound: [], outbound: [])
        let summary = EC2SecurityRuleSummary(groups: [group])
        XCTAssertEqual(summary.inbound.count, 0)
        XCTAssertEqual(summary.outbound.count, 0)
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", .dark)] {
            let locale = Locale(identifier: language)
            let mounted = mount(ScrollView { EC2SecurityRulesView(groups: [group]).padding() },
                                width: 480, height: 700, language: language, scheme: scheme)
            defer { mounted.window.close() }
            let name = "empty-rules-\(language)-\(scheme == .dark ? "dark" : "light")"
            let rendered = try renderedText(in: mounted, language: language, name: name)
            XCTAssertTrue(values(in: mounted.view).contains(group.groupId))
            for key in ["Inbound rules", "Outbound rules", "No inbound rules returned.", "No outbound rules returned."] {
                XCTAssertTrue(contains(L10n.text(key, locale: locale), in: rendered), "Missing rendered \(key)")
            }
            try writeEvidence("Both empty directions rendered and exact summary counts are 0. The small 0 glyph is ambiguous to Vision (0/o); the saved native screenshot requires visual count verification. No letter-to-digit substitution is accepted.\n",
                              name: name + "-count-evidence.txt")
        }
    }

    func testActualSecurityTabKeepsLoadingAndFailureSeparateFromZeroRulesAndRetryLoadsOnlySecurity() async throws {
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", .dark)] {
            let locale = Locale(identifier: language)
            let gate = EC2SecurityPresentationGate()
            var calls: [EC2DetailSection: Int] = [:]
            let row = EC2SecurityRulesFixture.instance()
            let vm = EC2ViewModel(detailLoader: { EC2SecurityRulesFixture.detail($0) }, sectionLoader: { _, section in
                calls[section, default: 0] += 1
                if calls[section] == 1 {
                    await gate.wait()
                    throw EC2SecurityPresentationError.unavailable
                }
                return .security(EC2SecurityRulesFixture.longGroups)
            })
            vm.selectedInstance = row
            await vm.waitForCurrentDetail()
            let mounted = mount(EC2DetailView(instance: row, vm: vm, tab: .security), width: 480, height: 1_500,
                                language: language, scheme: scheme)
            defer {
                mounted.window.close()
                vm.cancelLoading()
                Task { await gate.open() }
            }
            // The view model publishes .loading before its child task invokes the loader.
            try await until { vm.sectionStates[.security] == .loading && calls[.security] == 1 }
            XCTAssertEqual(calls, [.security: 1])
            let loading = try renderedText(in: mounted, language: language, name: "security-loading-\(language)")
            assertNoEmptyRuleResult(in: loading, locale: locale)
            await gate.open()
            await vm.waitForDetailSection(.security)
            XCTAssertEqual(vm.sectionStates[.security], .failed(EC2SecurityPresentationError.unavailable.localizedDescription))
            XCTAssertNil(vm.detailError)
            let failed = try renderedText(in: mounted, language: language, name: "security-error-\(language)")
            XCTAssertTrue(contains(L10n.text("Retry", locale: locale), in: failed))
            assertNoEmptyRuleResult(in: failed, locale: locale)

            try pressRetry(in: mounted, rendered: failed, title: L10n.text("Retry", locale: locale))
            try await until { vm.sectionStates[.security] == .loaded }
            let loaded = try renderedText(in: mounted, language: language, name: "security-retry-success-\(language)")
            XCTAssertTrue(contains(L10n.text("Inbound rules", locale: locale), in: loaded))
            XCTAssertTrue(contains(L10n.format("%@ rules", "3", locale: locale), in: loaded))
            XCTAssertEqual(calls, [.security: 2], "The actual Retry must refresh only its failed security group")
            XCTAssertNil(vm.detailError)
            XCTAssertEqual(vm.instanceDetail?.securityGroups, EC2SecurityRulesFixture.longGroups)
            try writeEvidence("Actual EC2DetailView Security: loading and failure did not expose normal empty states. Retry located from actual rendered pixels and clicked within the test-owned window; Security loaded twice total, Storage/Status remained 0.\n",
                              name: "security-retry-\(language).txt")
        }
    }

    private func assertNoEmptyRuleResult(in rendered: [RenderedText], locale: Locale) {
        for key in ["No inbound rules returned.", "No outbound rules returned.", "Inbound rules", "Outbound rules"] {
            XCTAssertFalse(contains(L10n.text(key, locale: locale), in: rendered))
        }
    }

    private struct Mounted {
        let view: NSHostingView<AnyView>
        let window: NSWindow
    }

    private struct RenderedText {
        let value: String
        let bounds: CGRect
    }

    private func mount<Content: View>(_ content: Content, width: CGFloat, height: CGFloat,
                                     language: String, scheme: ColorScheme) -> Mounted {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = content.frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
        let view = NSHostingView(rootView: AnyView(root))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.orderBack(nil)
        return Mounted(view: view, window: window)
    }

    private func bitmap(in mounted: Mounted) throws -> NSBitmapImageRep {
        let appearance = try XCTUnwrap(mounted.window.appearance)
        appearance.performAsCurrentDrawingAppearance {
            mounted.view.layoutSubtreeIfNeeded()
            mounted.window.displayIfNeeded()
            mounted.view.displayIfNeeded()
        }
        XCTAssertEqual(mounted.view.fittingSize.width, mounted.view.bounds.width, accuracy: 1)
        let bitmap = try XCTUnwrap(mounted.view.bitmapImageRepForCachingDisplay(in: mounted.view.bounds))
        appearance.performAsCurrentDrawingAppearance { mounted.view.cacheDisplay(in: mounted.view.bounds, to: bitmap) }
        return bitmap
    }

    private func renderedText(in mounted: Mounted, language: String, name: String) throws -> [RenderedText] {
        // SwiftUI's virtual AX children are absent in this offscreen harness. Read the actual pixels
        // for static headings/controls; keep native AX checks for complete selectable data fields.
        let bitmap = try bitmap(in: mounted)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: outputDirectory().appendingPathComponent(name + ".png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [language == "zh-Hans" ? "zh-Hans" : "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        let result = (request.results ?? []).compactMap { observation -> RenderedText? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RenderedText(value: candidate.string, bounds: observation.boundingBox)
        }
        try writeEvidence(result.map { "\($0.value) frame=\($0.bounds)" }.joined(separator: "\n") + "\n",
                          name: name + "-rendered-text.txt")
        return result
    }

    private func normalized(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace }
    }

    private func contains(_ expected: String, in rendered: [RenderedText]) -> Bool {
        let expected = normalized(expected)
        return rendered.contains { item in
            let value = normalized(item.value)
            guard let range = value.range(of: expected) else { return false }
            // A rendered 13 must never satisfy the expected count 3.
            if expected.first?.isNumber == true, range.lowerBound > value.startIndex {
                return !value[value.index(before: range.lowerBound)].isNumber
            }
            return true
        }
    }

    private func pressRetry(in mounted: Mounted, rendered: [RenderedText], title: String) throws {
        let bounds = try XCTUnwrap(rendered.first { normalized($0.value) == normalized(title) }?.bounds,
                                  "The actual Retry label must be present in the rendered window")
        let viewPoint = NSPoint(x: bounds.midX * mounted.view.bounds.width,
                               y: (mounted.view.isFlipped ? 1 - bounds.midY : bounds.midY) * mounted.view.bounds.height)
        let point = mounted.view.convert(viewPoint, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: mounted.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.001, windowNumber: mounted.window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        // Events are delivered only to this test-owned offscreen window, never the system mouse.
        NSApplication.shared.postEvent(up, atStart: true)
        mounted.window.sendEvent(down)
        mounted.window.sendEvent(up)
    }

    private func outputDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/ec2-security-rule-summary/screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeEvidence(_ value: String, name: String) throws {
        try value.write(to: outputDirectory().appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func values(in view: NSView) -> [String] {
        var queue: [NSObject] = [view]
        var seen: Set<ObjectIdentifier> = []
        var result: [String] = []
        while !queue.isEmpty && seen.count < 3_000 {
            let node = queue.removeFirst()
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            for name in ["accessibilityValue", "accessibilityLabel"] {
                let selector = NSSelectorFromString(name)
                if node.responds(to: selector), let value = node.perform(selector)?.takeUnretainedValue() as? String {
                    result.append(value)
                }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: children), let values = node.perform(children)?.takeUnretainedValue() as? [NSObject] {
                queue.append(contentsOf: values)
            }
            if let nativeView = node as? NSView { queue.append(contentsOf: nativeView.subviews) }
        }
        return result
    }

    private func until(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("Timed out waiting for native Security content", file: file, line: line)
        throw EC2SecurityPresentationError.timeout
    }
}

private actor EC2SecurityPresentationGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations = []
    }
}

private enum EC2SecurityPresentationError: LocalizedError {
    case unavailable, timeout
    var errorDescription: String? { "Loading cancelled. Use Refresh to try again." }
}
