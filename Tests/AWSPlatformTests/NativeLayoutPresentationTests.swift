import AppKit
import SwiftUI
import Vision
import XCTest
@testable import AWSPlatform

@MainActor
final class NativeLayoutPresentationTests: XCTestCase {
    func testSummaryChangesToTwoColumnsAtTheDocumentedBoundary() throws {
        for width: CGFloat in [679, 680] {
            let mounted = mount(summary(width: width), width: width, height: 2_400)
            defer { mounted.window.close() }
            let rendered = try renderedText(mounted, name: "summary-boundary-\(Int(width))")
            let identity = try XCTUnwrap(rendered.first { $0.value.contains("Identity and system") })
            let network = try XCTUnwrap(rendered.first { $0.value.contains("Network and addresses") })
            if width < 680 {
                XCTAssertLessThan(network.bounds.midY, identity.bounds.midY - 0.05,
                                  "The network summary must follow identity in a single column")
                XCTAssertEqual(network.bounds.minX, identity.bounds.minX, accuracy: 0.05)
            } else {
                XCTAssertEqual(network.bounds.midY, identity.bounds.midY, accuracy: 0.015)
                XCTAssertGreaterThan(network.bounds.minX, identity.bounds.minX + 0.3)
            }
        }
    }

    func testSummaryRetainsLongValuesAndTagsInBothLanguagesAndAppearances() throws {
        for language in ["en", "zh-Hans"] {
            for scheme in [ColorScheme.light, .dark] {
                for width: CGFloat in [480, 1_000] {
                    let mounted = mount(summary(width: width), width: width, height: 2_400,
                                        language: language, scheme: scheme)
                    defer { mounted.window.close() }
                    let name = "summary-\(language)-\(scheme == .dark ? "dark" : "light")-\(Int(width))"
                    try capture(mounted, name: name)
                    let values = accessibilityValues(mounted.view)
                    for value in [Self.row.imageId!, Self.longARN, Self.longTag] {
                        XCTAssertTrue(values.contains(value), "The actual native selectable field lost \(value)")
                    }
                    XCTAssertEqual(mounted.view.fittingSize.width, width, accuracy: 1,
                                   "Long identifiers must wrap inside the detail pane")
                }
            }
        }
    }

    func testSummaryKeepsUnloadedLoadingFailureAndLoadedEmptyDistinct() throws {
        let variants: [(String, EC2DetailSectionState, String)] = [
            ("unloaded", .notLoaded, "Not loaded"), ("loading", .loading, "Loading"),
            ("failed", .failed("Summary unavailable"), "Summary unavailable"),
            ("empty", .loaded, "No EBS volume details")
        ]
        for (name, state, expected) in variants {
            let content = EC2OverviewSummaryView(instance: Self.row, detail: Self.detail(Self.row.instanceId),
                                                sectionStates: [.storage: state, .security: state],
                                                cpuCreditFields: [], availableWidth: 1_000,
                                                onShowStorage: {}, onShowSecurity: {})
            let mounted = mount(content, width: 1_000, height: 1_800)
            defer { mounted.window.close() }
            let rendered = try renderedText(mounted, name: "summary-state-\(name)")
            XCTAssertTrue(rendered.contains { $0.value.contains(expected) })
            if state != .loaded {
                XCTAssertFalse(rendered.contains { $0.value.contains("No EBS volume details") })
                XCTAssertFalse(rendered.contains { $0.value.contains("No security group details") })
            }
        }
    }

    func testActualOverviewDoesNotPrefetchAndSummaryActionsLoadOnlyTheirTabs() async throws {
        var calls: [EC2DetailSection: Int] = [:]
        let vm = EC2ViewModel(detailLoader: { Self.detail($0) }, sectionLoader: { _, section in
            calls[section, default: 0] += 1
            switch section {
            case .storage: return .storage([])
            case .security: return .security([])
            }
        })
        vm.selectedInstance = Self.row
        await vm.waitForCurrentDetail()
        for width: CGFloat in [480, 680, 1_000] {
            let mounted = mount(EC2DetailView(instance: Self.row, vm: vm), width: width, height: 1_800)
            defer { mounted.window.close() }
            await settle()
            try capture(mounted, name: "actual-overview-\(Int(width))")
            XCTAssertEqual(calls, [:], "Rendering or changing the summary width must not read a section")
        }
        let mounted = mount(EC2DetailView(instance: Self.row, vm: vm), width: 1_000, height: 1_800)
        defer { mounted.window.close(); vm.cancelLoading() }
        await settle()
        XCTAssertFalse(accessibilityValues(mounted.view).contains("ip-10-0-12-84.example.internal"),
                       "Additional configuration starts collapsed")
        try toggleDisclosure("More configuration", in: mounted, name: "more-configuration-collapsed")
        await settle()
        XCTAssertTrue(accessibilityValues(mounted.view).contains("ip-10-0-12-84.example.internal"),
                      "Expanding the actual disclosure must reveal the already loaded DNS")
        XCTAssertTrue(accessibilityValues(mounted.view).contains("xen"))
        XCTAssertEqual(calls, [:], "Expanding additional base fields must not read a section")
        try capture(mounted, name: "more-configuration-expanded")
        try toggleDisclosure("More configuration", in: mounted, name: "more-configuration-collapse")
        await settle()
        try pressText("View storage", in: mounted, name: "storage-summary-entry")
        try await until { vm.sectionStates[.storage] == .loaded }
        XCTAssertEqual(calls, [.storage: 1])
        try activateSegment("Overview", in: mounted.view)
        await settle()
        try pressText("View security", in: mounted, name: "security-summary-entry")
        try await until { vm.sectionStates[.security] == .loaded }
        XCTAssertEqual(calls, [.storage: 1, .security: 1])
        try activateSegment("Status", in: mounted.view)
        await settle()
        let status = try renderedText(mounted, name: "actual-status-basic-fields")
        XCTAssertTrue(status.contains { $0.value.contains("Detailed Monitoring") })
        XCTAssertFalse(status.contains { $0.value.contains("System Status") || $0.value.contains("Scheduled Events") })
        XCTAssertEqual(calls, [.storage: 1, .security: 1])
    }

    func testNarrowHeaderKeepsSecondaryActionsAndInvokesInjectedCallbacksOnce() async throws {
        var favoriteCalls = 0
        var relationshipCalls = 0
        let content = EC2DetailHeaderView(instance: Self.row, scope: nil, isCurrentSelection: true,
                                          isFavorite: false, canToggleFavorite: true,
                                          onToggleFavorite: { favoriteCalls += 1 },
                                          onShowRelationships: { relationshipCalls += 1 })
            .padding()
        let mounted = mount(content, width: 480, height: 360)
        defer { mounted.window.close() }
        await settle()
        try capture(mounted, name: "narrow-header-actions")
        // SwiftUI's image buttons are focus-ring views, rather than NSButtons.
        // At this narrow width Connect occupies the first action row and the
        // copy/favorite/relationship controls follow from leading to trailing.
        let buttons = descendants(mounted.view).filter {
            String(describing: type(of: $0)) == "_FocusRingView" && !$0.isHiddenOrHasHiddenAncestor
        }.sorted {
            let first = $0.convert($0.bounds, to: mounted.view)
            let second = $1.convert($1.bounds, to: mounted.view)
            if abs(first.midY - second.midY) > 1 {
                return mounted.view.isFlipped ? first.midY < second.midY : first.midY > second.midY
            }
            return first.minX < second.minX
        }
        XCTAssertEqual(buttons.count, 4, "Connect and all three secondary controls must remain mounted")
        guard buttons.count == 4 else { return }
        for button in buttons {
            let frame = button.convert(button.bounds, to: mounted.view)
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(mounted.view.bounds.contains(frame), "Header actions must remain inside narrow content")
        }
        XCTAssertNil(EC2ConnectButton(instance: Self.row, scope: nil, isCurrentSelection: true).request,
                     "An absent verified scope must still disable Connect")
        try click(buttons[2], in: mounted)
        try click(buttons[3], in: mounted)
        await settle()
        XCTAssertEqual(favoriteCalls, 1)
        XCTAssertEqual(relationshipCalls, 1)
    }

    func testActualListQuickFiltersChangeVisibleRowsWithoutLoading() async throws {
        var listCalls = 0
        var detailCalls = 0
        let vm = EC2ViewModel(instanceLoader: { listCalls += 1; return [] }, detailLoader: {
            detailCalls += 1
            return Self.detail($0)
        })
        vm.instances = [Self.listRow("run-a", state: "running"), Self.listRow("run-b", state: "running"),
                        Self.listRow("stop-c", state: "stopped"), Self.listRow("wait-d", state: "pending")]
        let mounted = mount(EC2ListView(vm: vm), width: 320, height: 800)
        defer { mounted.window.close(); vm.cancelLoading() }
        await settle()
        for (title, state, names) in [("Running", "running", ["run-a", "run-b"]),
                                      ("Stopped", "stopped", ["stop-c"]),
                                      ("All", "All", ["run-a", "run-b", "stop-c", "wait-d"])] {
            try pressText(title, in: mounted, name: "list-before-\(state)", exact: false)
            await settle()
            XCTAssertEqual(vm.stateFilter, state)
            XCTAssertEqual(vm.filteredInstances.map(\.name), names)
            let rendered = try renderedText(mounted, name: "list-after-\(state)")
            for name in ["run-a", "run-b", "stop-c", "wait-d"] {
                XCTAssertEqual(rendered.contains { $0.value.contains(name) }, names.contains(name),
                               "The actual list must reflect the selected quick filter")
            }
            XCTAssertEqual(vm.loadedCount(for: state), names.count)
        }
        vm.stateFilter = "pending"
        await settle()
        XCTAssertTrue(accessibilityValues(mounted.view).contains { $0.contains("pending") })
        XCTAssertEqual(listCalls, 0, "Quick filtering must not refresh AWS resources")
        XCTAssertEqual(detailCalls, 0, "Quick filtering must not select or load an instance")
    }

    private func summary(width: CGFloat) -> some View {
        EC2OverviewSummaryView(instance: Self.row, detail: Self.detail(Self.row.instanceId), sectionStates: [:],
                               cpuCreditFields: [("CPU Credit mode", "Unlimited")], availableWidth: width,
                               onShowStorage: {}, onShowSecurity: {})
            .padding()
    }

    private struct Mounted {
        let view: NSHostingView<AnyView>
        let window: NSWindow
    }

    private struct RenderedText {
        let value: String
        let bounds: CGRect
        let candidate: VNRecognizedText
        let imageRegion: CGRect

        func bounds(of text: String) throws -> CGRect {
            let range = try XCTUnwrap(value.range(of: text))
            let glyphs = try XCTUnwrap(try candidate.boundingBox(for: range)).boundingBox
            return CGRect(x: glyphs.minX, y: imageRegion.minY + glyphs.minY * imageRegion.height,
                          width: glyphs.width, height: glyphs.height * imageRegion.height)
        }
    }

    private func mount<Content: View>(_ content: Content, width: CGFloat, height: CGFloat,
                                     language: String = "en", scheme: ColorScheme = .light) -> Mounted {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = content.frame(width: width, height: height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
        let view = NSHostingView(rootView: AnyView(root))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.orderBack(nil)
        return Mounted(view: view, window: window)
    }

    @discardableResult
    private func capture(_ mounted: Mounted, name: String) throws -> NSBitmapImageRep {
        let appearance = try XCTUnwrap(mounted.window.appearance)
        appearance.performAsCurrentDrawingAppearance {
            mounted.view.layoutSubtreeIfNeeded()
            mounted.window.displayIfNeeded()
            mounted.view.displayIfNeeded()
        }
        let bitmap = try XCTUnwrap(mounted.view.bitmapImageRepForCachingDisplay(in: mounted.view.bounds))
        appearance.performAsCurrentDrawingAppearance { mounted.view.cacheDisplay(in: mounted.view.bounds, to: bitmap) }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/native-layout-redesign/ec2", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
        return bitmap
    }

    private func renderedText(_ mounted: Mounted, name: String) throws -> [RenderedText] {
        let bitmap = try capture(mounted, name: name)
        let image = try XCTUnwrap(bitmap.cgImage)
        // Vision downscales very tall snapshots, losing small native headings.
        // Recognize overlapping strips and map each real glyph box back to the
        // complete snapshot so column-position assertions remain meaningful.
        var result: [RenderedText] = []
        let stripHeight = 1_200
        for top in stride(from: 0, to: image.height, by: stripHeight - 100) {
            let height = min(stripHeight, image.height - top)
            let strip = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: height)))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: strip, options: [:]).perform([request])
            result += (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first.map {
                    let box = observation.boundingBox
                    return RenderedText(value: $0.string, bounds: CGRect(
                        x: box.minX, y: (CGFloat(image.height - top - height) + box.minY * CGFloat(height)) / CGFloat(image.height),
                        width: box.width, height: box.height * CGFloat(height) / CGFloat(image.height)),
                        candidate: $0, imageRegion: CGRect(x: 0, y: CGFloat(image.height - top - height) / CGFloat(image.height),
                                                          width: 1, height: CGFloat(height) / CGFloat(image.height)))
                }
            }
        }
        return result
    }

    private func pressText(_ title: String, in mounted: Mounted, name: String, exact: Bool = true) throws {
        let rendered = try renderedText(mounted, name: name)
        // Vision may include the disclosure chevron before its text label.
        let label = try XCTUnwrap(rendered.first { exact ? $0.value.hasSuffix(title) : $0.value.hasPrefix(title) })
        let bounds = try label.bounds(of: title)
        let viewPoint = NSPoint(x: bounds.midX * mounted.view.bounds.width,
                               y: (mounted.view.isFlipped ? 1 - bounds.midY : bounds.midY) * mounted.view.bounds.height)
        try click(at: mounted.view.convert(viewPoint, to: nil), in: mounted)
    }

    private func toggleDisclosure(_ title: String, in mounted: Mounted, name: String) throws {
        let label = try XCTUnwrap(try renderedText(mounted, name: name).first { $0.value.contains(title) })
        let bounds = try label.bounds(of: title)
        let textFrame = CGRect(x: bounds.minX * mounted.view.bounds.width,
                               y: (mounted.view.isFlipped ? 1 - bounds.maxY : bounds.minY) * mounted.view.bounds.height,
                               width: bounds.width * mounted.view.bounds.width,
                               height: bounds.height * mounted.view.bounds.height)
        // A standard macOS disclosure's label is not the toggle. Its small
        // native focus-ring view immediately before the label is the arrow.
        let arrow = try XCTUnwrap(descendants(mounted.view).first { view in
            guard String(describing: type(of: view)) == "_FocusRingView", !view.isHiddenOrHasHiddenAncestor else { return false }
            let frame = view.convert(view.bounds, to: mounted.view)
            return frame.width > 0 && frame.width <= 20 && frame.height > 0 && frame.height <= 20
                && abs(frame.midY - textFrame.midY) <= max(frame.height, textFrame.height)
                && frame.maxX <= textFrame.minX && textFrame.minX - frame.maxX < 30
        }, "The actual native disclosure arrow must precede its label")
        try click(arrow, in: mounted)
    }

    private func click(_ view: NSView, in mounted: Mounted) throws {
        try click(at: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), in: mounted)
    }

    private func click(at point: NSPoint, in mounted: Mounted) throws {
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: mounted.window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime + 0.001, windowNumber: mounted.window.windowNumber,
                                                 context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        NSApplication.shared.postEvent(up, atStart: true)
        mounted.window.sendEvent(down)
        mounted.window.sendEvent(up)
    }

    private func activateSegment(_ title: String, in view: NSView) throws {
        let control = try XCTUnwrap(descendants(view).compactMap { $0 as? NSSegmentedControl }.first { control in
            !control.isHiddenOrHasHiddenAncestor && (0..<control.segmentCount).contains { control.label(forSegment: $0) == title }
        })
        let index = try XCTUnwrap((0..<control.segmentCount).first { control.label(forSegment: $0) == title })
        control.selectedSegment = index
        XCTAssertTrue(control.sendAction(control.action, to: control.target))
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func accessibilityValues(_ view: NSView) -> [String] {
        var queue: [NSObject] = [view]
        var seen: Set<ObjectIdentifier> = []
        var values: [String] = []
        while !queue.isEmpty && seen.count < 2_000 {
            let node = queue.removeFirst()
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            for key in ["accessibilityValue", "accessibilityLabel"] {
                let selector = NSSelectorFromString(key)
                if node.responds(to: selector), let value = node.perform(selector)?.takeUnretainedValue() as? String {
                    values.append(value)
                }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: children), let children = node.perform(children)?.takeUnretainedValue() as? [NSObject] {
                queue.append(contentsOf: children)
            }
            if let native = node as? NSView { queue.append(contentsOf: native.subviews) }
        }
        return values
    }

    private func settle() async {
        for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(15)) }
    }

    private func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("Timed out waiting for the actual native view and mock section state")
        throw NSError(domain: "NativeLayoutPresentationTests", code: 1)
    }

    private static let longARN = "arn:aws:iam::123456789012:instance-profile/" + String(repeating: "long-profile-", count: 12)
    private static let longTag = "中文部署标签-" + String(repeating: "long-tag-value-", count: 10)
    private static func listRow(_ name: String, state: String) -> EC2InstanceModel {
        EC2InstanceModel(instanceId: "i-\(name)", name: name, instanceType: "t3.large", state: state,
                         privateIP: "10.0.12.84", publicIP: nil, platformDetails: nil, architecture: nil,
                         vpcId: nil, subnetId: nil, availabilityZone: nil, securityGroups: [], imageId: nil,
                         imageName: nil, keyName: nil, launchTime: nil, tags: [:])
    }
    private static var row: EC2InstanceModel {
        EC2InstanceModel(instanceId: "i-summary-preview", name: "Production-中文-" + String(repeating: "service-", count: 7),
                         instanceType: "t3.large", state: "running", privateIP: "10.0.12.84", publicIP: "198.51.100.24",
                         platformDetails: "Linux / UNIX", architecture: "x86_64", vpcId: "vpc-0123456789abcdef0",
                         subnetId: "subnet-0123456789abcdef0", availabilityZone: "eu-central-1a",
                         securityGroups: ["sg-offline"], imageId: "ami-0123456789abcdef0", imageName: nil,
                         keyName: "offline-key", launchTime: nil, tags: ["deployment": longTag])
    }

    private static func detail(_ id: String) -> EC2InstanceDetailModel {
        EC2InstanceDetailModel(instanceId: id, privateDNSName: "ip-10-0-12-84.example.internal", publicDNSName: nil,
                               ipv6Address: "2001:db8:abcd:1234:5678:90ab:cdef:0000", monitoringState: "disabled",
                               stateTransitionReason: "-", iamProfileARN: longARN, rootDeviceName: "/dev/xvda",
                               rootDeviceType: "ebs", virtualizationType: "hvm", hypervisor: "xen", lifecycle: nil,
                               spotRequestId: nil, capacityReservationId: nil, cpuCoreCount: 1, threadsPerCore: 2,
                               ebsOptimized: true, enaSupport: true, sourceDestCheck: true, metadataHttpEndpoint: nil,
                               metadataHttpTokens: nil, metadataHopLimit: nil, metadataTags: nil, networkInterfaces: [],
                               volumes: [], securityGroups: [], warnings: [], cpuCreditMode: .unlimited)
    }
}
