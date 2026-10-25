import AppKit
import SwiftUI
import Vision
import XCTest
@testable import AWSPlatform

@MainActor
final class AWSCLISettingsPresentationTests: XCTestCase {
    func testNativeSectionKeepsCompactVersionsChannelsAndActionsAcrossLanguagesAndAppearances() async throws {
        let fixtures: [(String, AWSCLIInstallSource?)] = [
            ("official", .officialPackage),
            ("homebrew", .homebrew(prefix: URL(fileURLWithPath: "/opt/homebrew"),
                                    executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"))),
            ("unmanaged", .unmanaged), ("missing", nil)
        ]
        for (name, source) in fixtures {
            for language in ["en", "zh-Hans"] {
                for scheme in [ColorScheme.light, .dark] {
                    let probe = CLISettingsProbe(source: source)
                    let vm = makeViewModel(probe)
                    let mounted = mount(section(vm), language: language, scheme: scheme)
                    defer { mounted.window.close() }
                    await settle()
                    await vm.waitForCurrentTask()
                    await settle()
                    let suffix = "\(name)-\(language)-\(scheme == .dark ? "dark" : "light")"
                    let rendered = try capture(mounted, name: suffix, language: language)
                    XCTAssertTrue(rendered.contains { $0.value.contains("AWS CLI") })
                    let locale = Locale(identifier: language)
                    let text = values(mounted.view)
                    let visibleText = normalized(rendered.map(\.value).joined())
                    XCTAssertFalse(text.contains(CLISettingsProbe.executable.path))
                    XCTAssertFalse(text.contains(CLISettingsProbe.resolved.path))
                    XCTAssertFalse(visibleText.contains("offline-settings-preview"))
                    for removedLabel in ["Available version", "可用版本"] {
                        XCTAssertFalse(visibleText.contains(normalized(removedLabel)))
                    }
                    XCTAssertFalse(visibleText.contains("2.99.0"), "The available version must not add another summary row")
                    // Form omits virtual buttons from this NSView AX traversal.
                    // Chinese control labels are checked by localization tests and
                    // review of these retained screenshots; English also has click coverage.
                    if language == "en" {
                        assertVisible(L10n.text("Check", locale: locale), in: rendered)
                        assertVisible(L10n.text("Update", locale: locale), in: rendered)
                    }
                    if let source {
                        assertVisible("2.37.9", in: rendered)
                        XCTAssertTrue(text.contains("2.37.9"))
                        XCTAssertTrue(text.contains(L10n.text(source.displayName, locale: locale)),
                                      "The full localized installation source must remain accessible: \(suffix)")
                    }
                    if source?.supportsAutomaticUpdate != true {
                        assertVisible(L10n.text("AWS CLI installation guide", locale: locale), in: rendered)
                        XCTAssertFalse(vm.canUpdate)
                    } else {
                        XCTAssertFalse(identifiers(mounted.view).contains("aws-cli-status"))
                        XCTAssertFalse(visibleText.contains(normalized(L10n.text(vm.status, locale: locale))),
                                       "Routine check results must not add a permanent status row")
                        let explanation = source == .officialPackage
                            ? "AWS CLI updates start only when you click Update. macOS may ask for administrator authorization. Quitting and app restarts wait until the update finishes."
                            : "AWS CLI updates use this Homebrew installation and may update required dependencies. Quitting and app restarts wait until the update finishes."
                        XCTAssertFalse(visibleText.contains(normalized(L10n.text(explanation, locale: locale))),
                                       "Update instructions must not remain as a permanent footer")
                    }
                    XCTAssertEqual(mounted.view.fittingSize.width, 560, accuracy: 1)
                    let counts = await probe.counts()
                    XCTAssertEqual(counts.installs, 0, "Rendering and checking must never invoke an installer")
                    XCTAssertEqual(counts.detections, 1, "The initial native task must check only once")
                }
            }
        }
    }

    func testNativeUpdateButtonRunsOneMockInstallerAndDisplaysItsStage() async throws {
        let probe = CLISettingsProbe(source: .officialPackage)
        let vm = makeViewModel(probe)
        let mounted = mount(section(vm))
        defer {
            mounted.window.close()
            Task { await probe.finishInstallation() }
        }
        await settle()
        await vm.waitForCurrentTask()
        await settle()
        XCTAssertTrue(vm.canUpdate)
        try press("Update", in: mounted, name: "before-update")
        try await until { vm.isUpdating && vm.phase == .installing }
        await settle()
        let installing = try capture(mounted, name: "installing", language: "en")
        XCTAssertTrue(installing.contains { $0.value.contains("Installing AWS CLI") })
        XCTAssertFalse(vm.canUpdate)
        XCTAssertFalse(vm.canCheck)
        try press("Update", in: mounted, name: "update-disabled")
        await settle()
        let counts = await probe.counts()
        XCTAssertEqual(counts.installs, 1, "Repeated native clicks must not start another installer")
        await probe.finishInstallation()
        await vm.waitForCurrentTask()
        await settle()
        XCTAssertFalse(vm.isUpdating)
        XCTAssertEqual(vm.installation?.version, AWSCLIVersion("2.99.0"))
        XCTAssertFalse(vm.canUpdate)
        try capture(mounted, name: "updated", language: "en")
    }

    func testCheckFailureKeepsTheDetectedInstallationAndReadableError() async throws {
        let probe = CLISettingsProbe(source: .officialPackage, failLatest: true)
        let vm = makeViewModel(probe)
        let mounted = mount(section(vm), language: "zh-Hans", scheme: .dark)
        defer { mounted.window.close() }
        await settle()
        await vm.waitForCurrentTask()
        await settle()
        XCTAssertNotNil(vm.installation)
        let error = try XCTUnwrap(vm.error)
        XCTAssertFalse(vm.canUpdate)
        let rendered = try capture(mounted, name: "check-failure-zh-dark", language: "zh-Hans")
        assertVisible("2.37.9", in: rendered)
        assertVisible(L10n.text(AWSCLIInstallSource.officialPackage.displayName, locale: Locale(identifier: "zh-Hans")), in: rendered)
        assertVisible(L10n.text(error, locale: Locale(identifier: "zh-Hans")), in: rendered)
        let counts = await probe.counts()
        XCTAssertEqual(counts.installs, 0)
    }

    func testFullSettingsKeepsNativeScrollableLayoutAtDocumentedWindowSize() async throws {
        let suite = "AWSCLISettingsPresentationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = LanguageSettings(defaults: defaults)
        let transfers = TransferActivity()
        let appUpdates = AppUpdateController(transfers: transfers)
        let probe = CLISettingsProbe(source: .officialPackage)
        let cli = makeViewModel(probe, transfers: transfers)
        let view = SettingsView(settings: preferences, updates: appUpdates,
                                transfers: transfers, cliUpdates: cli)
        let mounted = mount(view)
        defer { mounted.window.close() }
        await settle()
        await cli.waitForCurrentTask()
        await settle()
        XCTAssertEqual(mounted.view.fittingSize.width, 560, accuracy: 1)
        XCTAssertEqual(mounted.view.fittingSize.height, 680, accuracy: 1)
        let scroll = try XCTUnwrap(descendants(mounted.view).compactMap { $0 as? NSScrollView }.first)
        XCTAssertTrue(scroll.hasVerticalScroller || scroll.documentView != nil,
                      "Settings must retain the native form's scroll container")
        try capture(mounted, name: "full-settings-top", language: "en")
        if let document = scroll.documentView {
            let target = NSPoint(x: 0, y: document.isFlipped ? max(0, document.bounds.height - scroll.contentSize.height) : 0)
            scroll.contentView.scroll(to: target)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        await settle()
        try capture(mounted, name: "full-settings-bottom", language: "en")
        let counts = await probe.counts()
        XCTAssertEqual(counts.installs, 0)
    }

    private func makeViewModel(_ probe: CLISettingsProbe, transfers: TransferActivity? = nil) -> AWSCLIUpdateViewModel {
        AWSCLIUpdateViewModel(detect: { try await probe.detect() }, latest: { _ in try await probe.latest() },
            install: { installation, version, progress in try await probe.install(installation, to: version, progress: progress) },
            activity: transfers ?? TransferActivity(), gate: AWSCLIOperationGate())
    }

    private func section(_ vm: AWSCLIUpdateViewModel) -> some View {
        Form { AWSCLISettingsSection(updates: vm) }.formStyle(.grouped)
    }

    private struct Mounted {
        let view: NSHostingView<AnyView>
        let window: NSWindow
    }

    private struct RenderedText {
        let value: String
        let candidate: VNRecognizedText
    }

    private func normalized(_ value: String) -> String { value.filter { !$0.isWhitespace } }

    private func assertVisible(_ text: String, in rendered: [RenderedText],
                               file: StaticString = #filePath, line: UInt = #line) {
        // SwiftUI's Form exposes some Text and Link rows as virtual elements,
        // outside the NSView accessibility traversal. Verify their complete
        // visible glyphs in the actual native screenshot instead.
        XCTAssertTrue(normalized(rendered.map(\.value).joined()).contains(normalized(text)),
                      "The full native text must remain visibly readable: \(text)", file: file, line: line)
    }

    private func mount<Content: View>(_ content: Content, language: String = "en",
                                      scheme: ColorScheme = .light) -> Mounted {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = content.frame(width: 560, height: 680, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
        let view = NSHostingView(rootView: AnyView(root))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 560, height: 680),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.orderBack(nil)
        return Mounted(view: view, window: window)
    }

    @discardableResult
    private func capture(_ mounted: Mounted, name: String, language: String) throws -> [RenderedText] {
        let appearance = try XCTUnwrap(mounted.window.appearance)
        appearance.performAsCurrentDrawingAppearance {
            mounted.view.layoutSubtreeIfNeeded()
            mounted.window.displayIfNeeded()
            mounted.view.displayIfNeeded()
        }
        let bitmap = try XCTUnwrap(mounted.view.bitmapImageRepForCachingDisplay(in: mounted.view.bounds))
        appearance.performAsCurrentDrawingAppearance { mounted.view.cacheDisplay(in: mounted.view.bounds, to: bitmap) }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/settings-footers/settings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = language == "en" ? ["en-US"] : ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first.map { RenderedText(value: $0.string, candidate: $0) } }
    }

    private func press(_ title: String, in mounted: Mounted, name: String) throws {
        let label = try XCTUnwrap(try capture(mounted, name: name, language: "en").first { $0.value.contains(title) })
        let range = try XCTUnwrap(label.value.range(of: title))
        let bounds = try XCTUnwrap(try label.candidate.boundingBox(for: range)).boundingBox
        let point = mounted.view.convert(NSPoint(x: bounds.midX * mounted.view.bounds.width,
            y: (mounted.view.isFlipped ? 1 - bounds.midY : bounds.midY) * mounted.view.bounds.height), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: mounted.window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.001, windowNumber: mounted.window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        NSApplication.shared.postEvent(up, atStart: true)
        mounted.window.sendEvent(down)
        mounted.window.sendEvent(up)
    }

    private func values(_ view: NSView) -> [String] { accessibilityStrings(view, keys: ["accessibilityValue", "accessibilityLabel"]) }
    private func identifiers(_ view: NSView) -> [String] { accessibilityStrings(view, keys: ["accessibilityIdentifier"]) }

    private func accessibilityStrings(_ view: NSView, keys: [String]) -> [String] {
        var queue: [NSObject] = [view]
        var seen: Set<ObjectIdentifier> = []
        var result: [String] = []
        while !queue.isEmpty && seen.count < 2_000 {
            let node = queue.removeFirst()
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            for key in keys {
                let selector = NSSelectorFromString(key)
                if node.responds(to: selector), let text = node.perform(selector)?.takeUnretainedValue() as? String { result.append(text) }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: children), let values = node.perform(children)?.takeUnretainedValue() as? [NSObject] { queue += values }
            if let native = node as? NSView { queue += native.subviews }
        }
        return result
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func settle() async { for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(15)) } }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("Timed out waiting for the native settings and mock update state")
        throw NSError(domain: "AWSCLISettingsPresentationTests", code: 1)
    }
}

private actor CLISettingsProbe {
    static let executable = URL(fileURLWithPath: "/opt/offline-settings-preview/" + String(repeating: "long-installation-prefix/", count: 5) + "bin/aws")
    static let resolved = URL(fileURLWithPath: "/opt/offline-settings-preview/" + String(repeating: "resolved-installation-prefix/", count: 4) + "aws-cli/aws")
    private let source: AWSCLIInstallSource?
    private let failLatest: Bool
    private var detections = 0
    private var installs = 0
    private var finish = false
    private var installed = false

    init(source: AWSCLIInstallSource?, failLatest: Bool = false) {
        self.source = source
        self.failLatest = failLatest
    }

    func detect() throws -> AWSCLIInstallation? {
        detections += 1
        return source.map { AWSCLIInstallation(executableURL: Self.executable, resolvedURL: Self.resolved,
            version: AWSCLIVersion(installed ? "2.99.0" : "2.37.9")!, source: $0) }
    }

    func latest() throws -> AWSCLIVersion {
        if failLatest { throw AWSCLIUpdateError.checkFailed }
        return AWSCLIVersion("2.99.0")!
    }

    func install(_ installation: AWSCLIInstallation, to version: AWSCLIVersion,
                 progress: @escaping @Sendable (AWSCLIUpdatePhase) -> Void) async throws {
        installs += 1
        progress(.installing)
        while !finish { try await Task.sleep(for: .milliseconds(15)) }
        installed = true
    }

    func finishInstallation() { finish = true }
    func counts() -> (detections: Int, installs: Int) { (detections, installs) }
}
