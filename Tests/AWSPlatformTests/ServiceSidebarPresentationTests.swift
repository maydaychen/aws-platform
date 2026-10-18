import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class ServiceSidebarPresentationTests: XCTestCase {
    func testDisclosureOnlyChangesExpansionAndChildSelectionUsesWholeRow() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SidebarPresentationState()
        let root = SidebarPresentationFixture(state: state, defaults: defaults)
        let (view, window) = mount(root, width: 620, height: 920)
        defer { window.close() }
        settle(view)
        let expandedCount = rows(view).count
        XCTAssertGreaterThanOrEqual(expandedCount, 16)
        try click(rowAt: 4, view: view, window: window)
        settle(view)
        XCTAssertFalse(defaults.bool(forKey: "sidebar.ec2Expanded"))
        XCTAssertEqual(state.service, .ebsVolumes)
        XCTAssertEqual(state.destination, .resources)
        // SwiftUI caches removed KeyViewProxy views; their count is not visibility.
        // Verify the user action and persistent state here; native renders cover visibility.
        try click(rowAt: 4, view: view, window: window)
        settle(view)
        XCTAssertTrue(defaults.bool(forKey: "sidebar.ec2Expanded"))
        let index = try XCTUnwrap(AWSService.ec2Services.firstIndex(of: .ebsSnapshots))
        try click(rowAt: 5 + index, view: view, window: window)
        settle(view)
        XCTAssertEqual(state.service, .ebsSnapshots)
        XCTAssertEqual(state.destination, .resources)
    }

    func testReturningFromSavedResourcesExpandsCurrentEC2Group() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "sidebar.ec2Expanded")
        let state = SidebarPresentationState()
        state.destination = .favorites
        let (view, window) = mount(SidebarPresentationFixture(state: state, defaults: defaults), width: 620, height: 920)
        defer { window.close() }
        settle(view)
        XCTAssertFalse(defaults.bool(forKey: "sidebar.ec2Expanded"))
        state.destination = .resources
        settle(view)
        XCTAssertTrue(defaults.bool(forKey: "sidebar.ec2Expanded"))
        try click(rowAt: 4, view: view, window: window)
        settle(view)
        state.service = .lambda
        settle(view)
        XCTAssertFalse(defaults.bool(forKey: "sidebar.ec2Expanded"))
        state.service = .ebsSnapshots
        settle(view)
        XCTAssertTrue(defaults.bool(forKey: "sidebar.ec2Expanded"))
    }

    func testCloudWatchDisclosurePersistsWithoutChangingDestinationOrService() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "sidebar.ec2Expanded")
        defaults.set(true, forKey: "sidebar.cloudWatchExpanded")
        let state = SidebarPresentationState()
        state.service = .logs
        state.destination = .recents
        let (view, window) = mount(SidebarPresentationFixture(state: state, defaults: defaults), width: 620, height: 1050)
        defer { window.close() }
        settle(view)
        let groupIndex = 5 + AWSService.ec2Services.count
        try click(rowAt: groupIndex, view: view, window: window)
        settle(view)
        XCTAssertFalse(defaults.bool(forKey: "sidebar.cloudWatchExpanded"))
        XCTAssertTrue(defaults.bool(forKey: "sidebar.ec2Expanded"))
        XCTAssertEqual(state.service, .logs)
        XCTAssertEqual(state.destination, .recents)
        try click(rowAt: groupIndex, view: view, window: window)
        settle(view)
        XCTAssertTrue(defaults.bool(forKey: "sidebar.cloudWatchExpanded"))
        XCTAssertEqual(state.destination, .recents)
        let childIndex = try XCTUnwrap(AWSService.cloudWatchServices.firstIndex(of: .alarms))
        try click(rowAt: groupIndex + 1 + childIndex, view: view, window: window)
        settle(view)
        XCTAssertEqual(state.service, .alarms)
        XCTAssertEqual(state.destination, .resources)
    }

    func testReturningToResourcesOrSelectingLogsExpandsOnlyCurrentCloudWatchGroup() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "sidebar.ec2Expanded")
        defaults.set(false, forKey: "sidebar.cloudWatchExpanded")
        let state = SidebarPresentationState()
        state.service = .logs
        state.destination = .favorites
        let (view, window) = mount(SidebarPresentationFixture(state: state, defaults: defaults), width: 620, height: 920)
        defer { window.close() }
        settle(view)
        XCTAssertFalse(defaults.bool(forKey: "sidebar.cloudWatchExpanded"))
        state.destination = .resources
        settle(view)
        XCTAssertTrue(defaults.bool(forKey: "sidebar.cloudWatchExpanded"))
        XCTAssertFalse(defaults.bool(forKey: "sidebar.ec2Expanded"))
        try click(rowAt: 5, view: view, window: window)
        settle(view)
        XCTAssertFalse(defaults.bool(forKey: "sidebar.cloudWatchExpanded"))
        state.service = .lambda
        settle(view)
        XCTAssertFalse(defaults.bool(forKey: "sidebar.cloudWatchExpanded"))
        state.service = .logs
        settle(view)
        XCTAssertTrue(defaults.bool(forKey: "sidebar.cloudWatchExpanded"))
        XCTAssertFalse(defaults.bool(forKey: "sidebar.ec2Expanded"))
    }

    func testCloudWatchGroupContainsBothChildrenWithoutChangingSavedAlarmServiceKey() {
        XCTAssertEqual(AWSService.cloudWatchServices, [.alarms, .logs])
        XCTAssertEqual(AWSService.alarms.rawValue, "CloudWatch")
        XCTAssertEqual(AWSService.logs.rawValue, "CloudWatch Logs")
        XCTAssertEqual(AWSService.alarms.sidebarTitle, "Alarms")
        XCTAssertEqual(AWSService.logs.sidebarTitle, "Logs")
        XCTAssertFalse(AWSService.standaloneServices.contains(.alarms))
        XCTAssertFalse(AWSService.standaloneServices.contains(.logs))
        for key in ["Alarms", "Logs", "Collapse CloudWatch group", "Expand CloudWatch group"] {
            XCTAssertNotEqual(L10n.text(key, locale: Locale(identifier: "zh-Hans")), key)
        }
    }

    func testNativeCloudWatchGroupingRendersBothLanguagesAndAppearances() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        for language in ["en", "zh-Hans"] {
            for scheme in [ColorScheme.light, .dark] {
                defaults.set(true, forKey: "sidebar.ec2Expanded")
                defaults.set(true, forKey: "sidebar.cloudWatchExpanded")
                let state = SidebarPresentationState()
                state.service = .logs
                let root = SidebarPresentationFixture(state: state, defaults: defaults)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.colorScheme, scheme)
                    .background(Color(nsColor: .windowBackgroundColor))
                let (view, window) = mount(root, width: 620, height: 1050, scheme: scheme)
                defer { window.close() }
                settle(view)
                let appearance = scheme == .dark ? "dark" : "light"
                try captureCloudWatch(view, name: "\(language)-\(appearance)-expanded")
                let groupIndex = 5 + AWSService.ec2Services.count
                try click(rowAt: groupIndex, view: view, window: window)
                settle(view)
                XCTAssertFalse(defaults.bool(forKey: "sidebar.cloudWatchExpanded"))
                XCTAssertEqual(state.service, .logs)
                try captureCloudWatch(view, name: "\(language)-\(appearance)-collapsed")
            }
        }
    }

    func testNativeEBSViewsRenderInBothLanguagesAndAppearances() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SidebarPresentationState()
        for kind in [EBSResource.Kind.volume, .snapshot] {
            let vm = EBSViewModel(kind: kind) { _, _ in [ebsRow(kind)] }
            vm.configure(scope: ebsScope()); await vm.loadResources()
            vm.selectedResource = vm.resources[0]
            state.service = kind.service
            for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", .dark)] {
                defaults.set(true, forKey: "sidebar.ec2Expanded")
                let root = HStack(spacing: 0) {
                    ServiceSidebarView(selectedService: Binding(get: { state.service }, set: { state.service = $0 }),
                                       destination: Binding(get: { state.destination }, set: { state.destination = $0 }), defaults: defaults)
                    Divider()
                    EBSListView(vm: vm).frame(width: 300)
                    Divider()
                    EBSDetailView(vm: vm).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, scheme)
                .background(Color(nsColor: .windowBackgroundColor))
                let (view, window) = mount(root, width: WorkspaceLayout.minimumWindowWidth, height: 900, scheme: scheme)
                defer { window.close() }
                settle(view)
                let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                XCTAssertGreaterThan(image.pixelsWide, 0)
                XCTAssertGreaterThan(image.pixelsHigh, 0)
                try capture(image, name: "\(language)-\(kind == .volume ? "volumes" : "snapshots")")
                XCTAssertEqual(vm.selectedResource?.kind, kind)
                XCTAssertEqual(vm.scope, ebsScope())
                if language == "zh-Hans" {
                    try click(rowAt: 4, view: view, window: window)
                    settle(view)
                    XCTAssertEqual(vm.selectedResource?.kind, kind)
                    // Reusing the prior bitmap can retain stale cached regions after layout changes.
                    let collapsedImage = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: collapsedImage)
                    try capture(collapsedImage, name: "\(language)-\(kind == .volume ? "volumes" : "snapshots")-collapsed")
                }
            }
        }
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "SidebarPresentation.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    private func mount<Content: View>(_ root: Content, width: Double, height: Double, scheme: ColorScheme = .light) -> (NSHostingView<Content>, NSWindow) {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.orderBack(nil)
        return (view, window)
    }

    private func settle(_ view: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        view.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func rows(_ view: NSView) -> [NSView] {
        // Only sidebar buttons: resource rows and detail controls occupy the other panes.
        descendants(view).filter {
            String(describing: type(of: $0)) == "KeyViewProxy" && $0.convert($0.bounds, to: view).maxX <= WorkspaceLayout.sidebarWidth + 1
        }.sorted { $0.convert($0.bounds, to: view).minY < $1.convert($1.bounds, to: view).minY }
    }

    private func click(rowAt index: Int, view: NSView, window: NSWindow) throws {
        let controls = rows(view)
        let row = try XCTUnwrap(controls.indices.contains(index) ? controls[index] : nil)
        let point = row.convert(NSPoint(x: row.bounds.maxX - 6, y: row.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
    }

    private func capture(_ image: NSBitmapImageRep, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["AWS_PLATFORM_EBS_SCREENSHOTS"] else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }

    private func captureCloudWatch(_ view: NSView, name: String) throws {
        view.displayIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        XCTAssertGreaterThan(image.pixelsWide, 0)
        XCTAssertGreaterThan(image.pixelsHigh, 0)
        let path = ProcessInfo.processInfo.environment["AWS_PLATFORM_SUBMODULE_SCREENSHOTS"]
            ?? ".tmp/service-submodules/screenshots/navigation"
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
}

@MainActor
private final class SidebarPresentationState: ObservableObject {
    @Published var service = AWSService.ebsVolumes
    @Published var destination = WorkspaceDestination.resources
}

@MainActor
private struct SidebarPresentationFixture: View {
    @ObservedObject var state: SidebarPresentationState
    let defaults: UserDefaults
    var body: some View {
        HStack(spacing: 0) {
            ServiceSidebarView(selectedService: $state.service, destination: $state.destination, defaults: defaults)
            Text(state.service.rawValue).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
