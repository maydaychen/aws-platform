import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class EC2ConnectPresentationTests: XCTestCase {
    func testNativeButtonOnlyHandsOffCurrentRunningSelectionAndUsesNewScope() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/ec2-ssm/presentation/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = ConnectPresentationState()
        var scripts: [String] = []
        let service = EC2SSMConnectionService(cli: { URL(fileURLWithPath: "/offline/aws") },
            plugin: { URL(fileURLWithPath: "/offline/session-manager-plugin") },
            open: { url in
                scripts.append((try? String(contentsOf: url)) ?? "")
                return true
            }, temporaryDirectory: root)
        let (view, window) = mount(ConnectButtonFixture(state: state, service: service), width: 480, height: 100)
        defer { window.close() }
        try clickButton(view, window: window)
        XCTAssertEqual(scripts.count, 1)
        state.scope = nil
        try clickButton(view, window: window)
        XCTAssertEqual(scripts.count, 1, "No verified Profile must disable Connect")
        state.scope = ebsScope(profile: "other-profile", region: "us-west-2")
        state.currentSelection = false
        try clickButton(view, window: window)
        XCTAssertEqual(scripts.count, 1, "A stale instance must not use a new scope")
        state.currentSelection = true
        state.instance = connectInstance(state: "stopped", zone: "us-west-2a")
        try clickButton(view, window: window)
        XCTAssertEqual(scripts.count, 1)
        state.instance = connectInstance(zone: "us-west-2a")
        try clickButton(view, window: window)
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts.last?.contains("--profile 'other-profile' --region 'us-west-2'") == true)
    }

    func testEC2ScopeIsClearedOnResetAndReplacedWithoutLoadingAWS() {
        let vm = EC2ViewModel()
        let provider = AWSServiceProvider()
        XCTAssertNil(vm.scope)
        vm.configure(provider: provider, scope: ebsScope(), refreshImmediately: false)
        XCTAssertEqual(vm.scope, ebsScope())
        vm.configure(provider: provider, scope: ebsScope(profile: "next-profile"), refreshImmediately: false)
        XCTAssertEqual(vm.scope?.profile.name, "next-profile")
        vm.reset()
        XCTAssertNil(vm.scope)
        XCTAssertNil(vm.selectedInstance)
    }

    func testDetailHeaderRendersInBothLanguagesAndAppearancesAtMinimumWidth() throws {
        for language in ["en", "zh-Hans"] {
            for scheme in [ColorScheme.light, .dark] {
                let vm = EC2ViewModel()
                let content = EC2DetailView(instance: connectInstance(), vm: vm)
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
                    .background(Color(nsColor: .windowBackgroundColor))
                let (view, window) = mount(content, width: 480, height: 640)
                defer { window.close() }
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                settle(view)
                // The bordered SwiftUI button renders through a focus-ring view;
                // its accessibility identifier is not an NSView identifier.
                let button = try XCTUnwrap(descendants(view).first { String(describing: type(of: $0)) == "_FocusRingView" })
                let frame = button.convert(button.bounds, to: view)
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, view.bounds.maxX)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let directory = ProcessInfo.processInfo.environment["AWS_PLATFORM_SSM_SCREENSHOTS"] {
                    let url = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: url.appendingPathComponent("\(language)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }

    private func mount<Content: View>(_ content: Content, width: Double, height: Double) -> (NSHostingView<Content>, NSWindow) {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        settle(view)
        return (view, window)
    }

    private func settle(_ view: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func clickButton(_ view: NSView, window: NSWindow) throws {
        settle(view)
        let button = try XCTUnwrap(descendants(view).first { String(describing: type(of: $0)) == "_FocusRingView" })
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.001, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        // Native bordered controls enter a local tracking loop on mouseDown.
        NSApplication.shared.postEvent(up, atStart: true)
        window.sendEvent(down)
        window.sendEvent(up)
    }
}

@MainActor
private final class ConnectPresentationState: ObservableObject {
    @Published var scope: MonitoringScope? = ebsScope()
    @Published var instance = connectInstance()
    @Published var currentSelection = true
}

@MainActor
private struct ConnectButtonFixture: View {
    @ObservedObject var state: ConnectPresentationState
    let service: EC2SSMConnectionService
    var body: some View {
        EC2ConnectButton(instance: state.instance, scope: state.scope,
                         isCurrentSelection: state.currentSelection, service: service).padding()
    }
}

private func connectInstance(state: String = "running", zone: String = "us-east-1a") -> EC2InstanceModel {
    .init(instanceId: "i-0123456789abcdef0", name: "Production application server with a long name",
          instanceType: "t3.micro", state: state, privateIP: "10.0.1.10", publicIP: nil,
          platformDetails: "Linux/UNIX", architecture: "x86_64", vpcId: nil, subnetId: nil,
          availabilityZone: zone, securityGroups: [], imageId: nil, imageName: nil, keyName: nil,
          launchTime: nil, tags: [:])
}
