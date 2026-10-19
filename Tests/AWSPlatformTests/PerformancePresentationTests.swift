import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class PerformancePresentationTests: XCTestCase {
    func testActualEC2TabsRequestOnlySelectedGroupAndReuseLoadedGroups() async throws {
        var calls: [EC2DetailSection: Int] = [:]
        let row = Self.instance()
        let vm = EC2ViewModel(detailLoader: { Self.instanceDetail($0) }, sectionLoader: { _, section in
            calls[section, default: 0] += 1
            switch section {
            case .storage: return .storage([])
            case .security: return .security([])
            case .status: return .status(Self.health())
            }
        })
        vm.selectedInstance = row
        await vm.waitForCurrentDetail()
        let mounted = mount(EC2DetailView(instance: row, vm: vm), width: 1_100, height: 800)
        defer { mounted.window.close() }
        try await until { self.segmentedControl(in: mounted.view, label: "Overview") != nil }
        XCTAssertTrue(calls.isEmpty, "Mounting Overview must not load any optional group")
        for (label, section) in [("Storage", EC2DetailSection.storage), ("Security", .security), ("Status", .status)] {
            try activateSegment(label, in: mounted.view)
            try await until { vm.sectionStates[section] == .loaded }
            XCTAssertEqual(calls[section], 1)
            XCTAssertEqual(calls.values.reduce(0, +), calls.count)
        }
        for label in ["Overview", "Storage", "Security", "Status", "Network"] {
            try activateSegment(label, in: mounted.view)
            await settle()
        }
        XCTAssertEqual(calls, [.storage: 1, .security: 1, .status: 1])
        try writeEvidence("EC2 native segmented target/action: Overview=0; Storage=1; Security=1; Status=1; revisits unchanged.\n",
                          named: "ec2-native-tab-actions.txt")
    }

    func testActualLambdaTabsRequestOnlySelectedGroupAndReuseLoadedGroups() async throws {
        var calls: [LambdaDetailSection: Int] = [:]
        let row = Self.function()
        let vm = LambdaViewModel(detailLoader: { Self.functionDetail($0) }, sectionLoader: { _, section in
            calls[section, default: 0] += 1
            return LambdaDetailSectionData()
        })
        vm.selectedFunction = row
        try await until { vm.functionDetail != nil && !vm.isDetailLoading }
        let mounted = mount(LambdaDetailView(function: row, vm: vm), width: 1_100, height: 800)
        defer { mounted.window.close() }
        try await until { self.segmentedControl(in: mounted.view, label: "Overview") != nil }
        XCTAssertTrue(calls.isEmpty, "Mounting Overview must not load any optional group")
        for (label, section) in [("Configuration", LambdaDetailSection.configuration), ("Triggers", .triggers), ("Versions", .versions)] {
            try activateSegment(label, in: mounted.view)
            try await until { vm.detailSectionState(section) == .loaded }
            XCTAssertEqual(calls[section], 1)
            XCTAssertEqual(calls.values.reduce(0, +), calls.count)
        }
        for label in ["Overview", "Configuration", "Triggers", "Versions"] {
            try activateSegment(label, in: mounted.view)
            await settle()
        }
        XCTAssertEqual(calls, [.configuration: 1, .triggers: 1, .versions: 1])
        try writeEvidence("Lambda native segmented target/action: Overview=0; Configuration=1; Triggers=1; Versions=1; revisits unchanged.\n",
                          named: "lambda-native-tab-actions.txt")
    }

    func testProgressiveListsAndIndependentSectionStatesFitBothLanguagesAndAppearances() async throws {
        let gate = PerformancePresentationGate()
        let ec2 = EC2ViewModel(instanceLoader: { [Self.instance()] }, imageNameLoader: { _ in
            await gate.wait()
            return [:]
        }, healthLoader: { _ in
            await gate.wait()
            return [:]
        }, detailLoader: { Self.instanceDetail($0) }, sectionLoader: { _, _ in
            await gate.wait()
            throw PerformancePresentationError.unavailable
        })
        let lambda = LambdaViewModel(functionLoader: { [Self.function()] }, detailLoader: { Self.functionDetail($0) },
                                     summaryLoader: { _ in
            await gate.wait()
            throw PerformancePresentationError.unavailable
        }, sectionLoader: { _, _ in
            await gate.wait()
            throw PerformancePresentationError.unavailable
        })
        let ec2Request = Task { await ec2.loadInstances(selectFirstIfNeeded: false) }
        let lambdaRequest = Task { await lambda.loadFunctions(selectFirstIfNeeded: false) }
        defer {
            ec2.cancelLoading()
            lambda.cancelLoading()
            Task { await gate.open() }
        }
        try await until {
            ec2.instances.count == 1 && ec2.isImageNameLoading && ec2.isHealthLoading
                && lambda.functions.count == 1 && lambda.isSummaryLoading
        }
        XCTAssertNil(lambda.functions[0].state)
        ec2.selectedInstance = ec2.instances[0]
        lambda.selectedFunction = lambda.functions[0]
        await ec2.waitForCurrentDetail()
        try await until { lambda.functionDetail != nil && !lambda.isDetailLoading }
        ec2.showDetailSection(.storage)
        lambda.selectDetailSection(.triggers)
        try await until { ec2.sectionStates[.storage] == .loading && lambda.detailSectionState(.triggers) == .loading }
        for (language, scheme) in Self.variants {
            try await snapshot(EC2ListView(vm: ec2), name: "ec2-list-progressive", width: 280, language: language, scheme: scheme)
            try await snapshot(LambdaListView(vm: lambda), name: "lambda-list-progressive", width: 280, language: language, scheme: scheme)
            try await snapshot(EC2DetailView(instance: Self.instance(), vm: ec2, tab: .storage),
                               name: "ec2-section-loading", width: 480, language: language, scheme: scheme,
                               header: Self.instance().name)
            try await snapshot(LambdaDetailView(function: Self.function(), vm: lambda, tab: .triggers),
                               name: "lambda-section-loading", width: 480, language: language, scheme: scheme,
                               header: Self.function().functionName)
        }
        await gate.open()
        await ec2Request.value
        await lambdaRequest.value
        await ec2.waitForDetailSection(.storage)
        await lambda.waitForDetailSection(.triggers)
        XCTAssertNotNil(lambda.summaryWarning)
        XCTAssertNil(ec2.detailError)
        XCTAssertNil(lambda.detailError)
        for (language, scheme) in Self.variants {
            try await snapshot(LambdaListView(vm: lambda), name: "lambda-list-summary-error", width: 280,
                               language: language, scheme: scheme)
            try await snapshot(EC2DetailView(instance: Self.instance(), vm: ec2, tab: .storage),
                               name: "ec2-section-error", width: 480, language: language, scheme: scheme,
                               header: Self.instance().name)
            try await snapshot(LambdaDetailView(function: Self.function(), vm: lambda, tab: .triggers),
                               name: "lambda-section-error", width: 480, language: language, scheme: scheme,
                               header: Self.function().functionName)
        }
    }

    func testActualCodeViewPublishesUnicodeMultilinePreviewAndScrollsLongLines() async throws {
        let longLine = "const longValue = \"" + String(repeating: "长行🙂abcdef", count: 150) + "\";"
        let source = "// Unicode 中文 café 👩🏽‍💻\nconst message = \"你好，世界\";\n\(longLine)\nexport { message };\n"
        var row = Self.function()
        row.codeFiles = [LambdaCodeFile(path: "src/Unicode示例.js", content: source, isBinary: false)]
        for (language, scheme) in Self.variants {
            let mounted = mount(LambdaCodeView(function: row), width: 720, height: 540, language: language, scheme: scheme)
            defer { mounted.window.close() }
            // Read the mounted view's accessibility value, not the standalone highlighter state.
            try await until { self.accessibilityValues(in: mounted.view).contains { $0.contains("你好，世界") && $0.contains("export { message }") } }
            let previewScroll = try XCTUnwrap(descendants(mounted.view).compactMap { $0 as? NSScrollView }.first {
                guard let document = $0.documentView else { return false }
                return document.frame.width > $0.contentView.bounds.width + 100
            }, "The actual source preview must retain a horizontally scrollable long line")
            let before = previewScroll.contentView.bounds.origin.x
            previewScroll.contentView.scroll(to: NSPoint(x: before + 120, y: previewScroll.contentView.bounds.origin.y))
            previewScroll.reflectScrolledClipView(previewScroll.contentView)
            XCTAssertGreaterThan(previewScroll.contentView.bounds.origin.x, before)
            previewScroll.contentView.scroll(to: .zero)
            previewScroll.reflectScrolledClipView(previewScroll.contentView)
            try capture(mounted, name: "lambda-code-unicode-\(language)-\(Self.schemeName(scheme))")
            let selectable = descendants(mounted.view).compactMap { $0 as? NSTextView }.first { $0.string == source && $0.isSelectable }
            if let selectable {
                let range = NSRange(location: 0, length: (source as NSString).length)
                selectable.setSelectedRange(range)
                XCTAssertEqual(selectable.selectedRange(), range)
                let pasteboard = NSPasteboard.withUniqueName()
                defer { pasteboard.releaseGlobally() }
                XCTAssertTrue(selectable.writeSelection(to: pasteboard, type: .string))
                XCTAssertEqual(pasteboard.string(forType: .string), source)
                try writeEvidence("Actual selectable NSTextView: full Unicode source selected and copied to private pasteboard.\n",
                                  named: "lambda-code-copy-\(language)-\(Self.schemeName(scheme)).txt")
            } else {
                try writeEvidence("Preview accessibility text and horizontal scrolling verified. SwiftUI does not expose a selectable NSTextView to this offscreen hierarchy; interactive text selection and copy remain unverified.\n",
                                  named: "lambda-code-copy-\(language)-\(Self.schemeName(scheme)).txt")
            }
        }
    }

    private static var variants: [(String, ColorScheme)] {
        [("en", .light), ("en", .dark), ("zh-Hans", .light), ("zh-Hans", .dark)]
    }

    private static func schemeName(_ scheme: ColorScheme) -> String { scheme == .dark ? "dark" : "light" }

    private struct Mounted {
        let window: NSWindow
        let view: NSHostingView<AnyView>
    }

    private func mount<Content: View>(_ content: Content, width: CGFloat, height: CGFloat,
                                     language: String = "en", scheme: ColorScheme = .light) -> Mounted {
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
        return Mounted(window: window, view: view)
    }

    private func snapshot<Content: View>(_ content: Content, name: String, width: CGFloat,
                                        language: String, scheme: ColorScheme, header: String? = nil) async throws {
        let mounted = mount(content, width: width, height: 800, language: language, scheme: scheme)
        defer { mounted.window.close() }
        await settle()
        if let header { try assertHeaderAtTop(header, in: mounted, name: "\(name)-\(language)-\(Self.schemeName(scheme))") }
        try capture(mounted, name: "\(name)-\(language)-\(Self.schemeName(scheme))")
    }

    private func assertHeaderAtTop(_ text: String, in mounted: Mounted, name: String) throws {
        mounted.view.layoutSubtreeIfNeeded()
        let contentFrame = mounted.window.convertToScreen(mounted.view.convert(mounted.view.bounds, to: nil))
        let frames = accessibilityNodes(in: mounted.view).compactMap { node -> NSRect? in
            guard accessibilityText(in: node).contains(text),
                  node.responds(to: NSSelectorFromString("accessibilityFrame")),
                  let value = node.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
            let frame = value.rectValue
            return frame.width > 0 && frame.height > 0 ? frame : nil
        }
        let frame = try XCTUnwrap(frames.min { $0.height < $1.height }, "The actual resource header must have an accessibility frame")
        let topInset = contentFrame.maxY - frame.maxY
        XCTAssertGreaterThanOrEqual(topInset, -1, "The resource header must remain inside the detail pane")
        XCTAssertLessThan(topInset, 40, "Loading and error content must not vertically center the resource header")
        try writeEvidence("\(name): actual resource header top inset=\(topInset) pt.\n",
                          named: "\(name)-header-position.txt")
    }

    private func capture(_ mounted: Mounted, name: String) throws {
        let appearance = try XCTUnwrap(mounted.window.appearance)
        appearance.performAsCurrentDrawingAppearance {
            mounted.view.layoutSubtreeIfNeeded()
            mounted.window.displayIfNeeded()
            mounted.view.displayIfNeeded()
        }
        XCTAssertEqual(mounted.view.fittingSize.width, mounted.view.bounds.width, accuracy: 1)
        let bitmap = try XCTUnwrap(mounted.view.bitmapImageRepForCachingDisplay(in: mounted.view.bounds))
        appearance.performAsCurrentDrawingAppearance { mounted.view.cacheDisplay(in: mounted.view.bounds, to: bitmap) }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: outputDirectory.appendingPathComponent("\(name).png"))
        let controls = descendants(mounted.view).filter { $0 is NSSegmentedControl || $0 is NSPopUpButton }
        let visibleControls = controls.filter(isVisible).map { String(describing: type(of: $0)) }
        try writeEvidence("Visible native picker controls: \(visibleControls)\nNative glyph pixels are not guaranteed by AppKit's offscreen bitmap renderer; screenshots cover selected child content.\n",
                          named: "\(name)-native-controls.txt")
    }

    private var outputDirectory: URL {
        let result = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/performance-improvements-20261020/screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    private func writeEvidence(_ value: String, named name: String) throws {
        try value.write(to: outputDirectory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func activateSegment(_ label: String, in view: NSView) throws {
        let control = try XCTUnwrap(segmentedControl(in: view, label: label), "A visible segmented picker must contain \(label)")
        let index = try XCTUnwrap((0..<control.segmentCount).first { control.label(forSegment: $0) == label })
        XCTAssertTrue(control.isEnabled)
        control.selectedSegment = index
        XCTAssertTrue(control.sendAction(control.action, to: control.target), "Invoke the actual native picker's target/action")
        XCTAssertEqual(control.selectedSegment, index)
    }

    private func segmentedControl(in view: NSView, label: String) -> NSSegmentedControl? {
        view.layoutSubtreeIfNeeded()
        return descendants(view).compactMap { $0 as? NSSegmentedControl }.first { control in
            isVisible(control) && (0..<control.segmentCount).contains { control.label(forSegment: $0) == label }
        }
    }

    private func isVisible(_ view: NSView) -> Bool {
        !view.isHiddenOrHasHiddenAncestor && view.window != nil && view.visibleRect.width > 1 && view.visibleRect.height > 1
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }

    private func accessibilityValues(in view: NSView) -> [String] {
        accessibilityNodes(in: view).flatMap(accessibilityText)
    }

    private func accessibilityText(in node: NSObject) -> [String] {
        ["accessibilityValue", "accessibilityLabel"].compactMap { name in
            let selector = NSSelectorFromString(name)
            guard node.responds(to: selector) else { return nil }
            return node.perform(selector)?.takeUnretainedValue() as? String
        }
    }

    private func accessibilityNodes(in view: NSView) -> [NSObject] {
        var queue: [NSObject] = [view]
        var seen: Set<ObjectIdentifier> = []
        var result: [NSObject] = []
        while !queue.isEmpty && seen.count < 2_000 {
            let node = queue.removeFirst()
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            result.append(node)
            let children = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: children), let values = node.perform(children)?.takeUnretainedValue() as? [NSObject] {
                queue.append(contentsOf: values)
            }
            if let nativeView = node as? NSView { queue.append(contentsOf: nativeView.subviews) }
        }
        return result
    }

    private func settle() async {
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private func until(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("Timed out waiting for the mounted native view or mock state", file: file, line: line)
        throw PerformancePresentationError.timeout
    }

    private static func instance() -> EC2InstanceModel {
        EC2InstanceModel(instanceId: "i-offline-preview", name: "Production-中文-" + String(repeating: "service-", count: 7),
                         instanceType: "t3.micro", state: "running", privateIP: nil, publicIP: nil,
                         platformDetails: nil, architecture: nil, vpcId: nil, subnetId: nil, availabilityZone: nil,
                         securityGroups: ["sg-a"], imageId: "ami-a", imageName: nil, keyName: nil, launchTime: nil, tags: [:])
    }

    private static func instanceDetail(_ id: String) -> EC2InstanceDetailModel {
        EC2InstanceDetailModel(instanceId: id, privateDNSName: "private.example", publicDNSName: nil, ipv6Address: nil,
                               monitoringState: nil, stateTransitionReason: nil, iamProfileARN: nil, rootDeviceName: nil,
                               rootDeviceType: nil, virtualizationType: nil, hypervisor: nil, lifecycle: nil,
                               spotRequestId: nil, capacityReservationId: nil, cpuCoreCount: nil, threadsPerCore: nil,
                               ebsOptimized: nil, enaSupport: nil, sourceDestCheck: nil, metadataHttpEndpoint: nil,
                               metadataHttpTokens: nil, metadataHopLimit: nil, metadataTags: nil, networkInterfaces: [],
                               volumes: [], securityGroups: [], health: nil, warnings: [], cpuCreditMode: .unlimited,
                               volumeIDs: ["vol-a"], securityGroupIDs: ["sg-a"])
    }

    private static func health() -> EC2InstanceHealth {
        EC2InstanceHealth(systemStatus: "ok", instanceStatus: "ok", attachedEBSStatus: nil, events: [])
    }

    private static func function() -> LambdaFunctionModel {
        LambdaFunctionModel(functionName: "Offline-中文-" + String(repeating: "function-", count: 5), runtime: "nodejs22.x",
                            state: nil, lastUpdateStatus: nil, lastModified: nil, memorySize: 128, arn: nil, handler: nil,
                            role: nil, codeSize: nil, timeout: 3, environment: [:], vpcConfig: nil, packageType: "Zip",
                            imageUri: nil, tags: [:], codeLocation: nil, codeFiles: [])
    }

    private static func functionDetail(_ name: String) -> LambdaFunctionDetailModel {
        LambdaFunctionDetailModel(functionName: name, description: nil, state: "Active", stateReason: nil,
                                  stateReasonCode: nil, lastUpdateStatus: "Successful", lastUpdateStatusReason: nil,
                                  lastUpdateStatusReasonCode: nil, version: "$LATEST", architectures: ["arm64"],
                                  runtimeVersionARN: nil, revisionId: nil, codeSHA256: nil, configSHA256: nil,
                                  ephemeralStorageMB: 512, environment: [:], environmentError: nil, vpcId: nil,
                                  subnetIds: [], securityGroupIds: [], ipv6AllowedForDualStack: nil, layers: [], fileSystems: [],
                                  deadLetterTargetARN: nil, tracingMode: nil, logGroup: "/aws/lambda/\(name)", logFormat: "Text",
                                  applicationLogLevel: nil, systemLogLevel: nil, kmsKeyARN: nil, sourceKMSKeyARN: nil,
                                  snapStartApplyOn: nil, snapStartOptimizationStatus: nil, imageEntryPoint: [], imageCommand: [],
                                  imageWorkingDirectory: nil, codeLocation: nil, imageURI: nil, resolvedImageURI: nil,
                                  repositoryType: nil, reservedConcurrency: nil, tags: [:], eventSources: [], asyncInvokeConfigs: [],
                                  functionURLs: [], versions: [], aliases: [], provisionedConcurrency: [], policyRevisionId: nil,
                                  policyStatements: [], warnings: [])
    }
}

private actor PerformancePresentationGate {
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

private enum PerformancePresentationError: LocalizedError {
    case unavailable
    case timeout
    var errorDescription: String? { "Loading cancelled. Use Refresh to try again." }
}
