import AppKit
import SwiftUI
import XCTest
@testable import AWSPlatform

@MainActor
final class AutoScalingInsightsPresentationTests: XCTestCase {
    func testActualDetailBindsUnconfiguredInsightsAndManualEntrypointsLoad() async throws {
        let group = asgInsightsGroup()
        let parent = await loadedParent(groups: [group])
        let probe = DetailInsightsProbe()
        let insights = makeInsights(probe)
        XCTAssertNil(insights.scope)
        XCTAssertNil(insights.group)
        let (view, window) = mountedDetail(parent, insights: insights)
        defer { window.close() }
        XCTAssertEqual(insights.scope, parent.scope)
        XCTAssertEqual(insights.group, group)
        let initialCalls = await probe.counts()
        XCTAssertEqual(initialCalls, [0, 0])
        scrollToBottom(view, window: window)
        try writeSnapshot(view, name: "actual-detail-before-ax-en")
        let templates = try insightButtons(in: view).templates
        try press(templates, in: view, window: window, index: 0)
        settle(view, window: window)
        await insights.waitForLoading()
        let templateCalls = await probe.counts()
        // A real click must invoke the first enabled button exactly once.
        XCTAssertEqual(templateCalls, [1, 0])
        XCTAssertEqual(insights.templateVersions.count, 1)
        // The loaded template fields move the second button down the document.
        scrollToBottom(view, window: window)
        let refreshes = try insightButtons(in: view).refreshes
        try press(refreshes, in: view, window: window, index: 1)
        settle(view, window: window)
        await insights.waitForLoading()
        XCTAssertEqual(insights.templateVersions.count, 1)
        XCTAssertEqual(insights.instanceRefreshes.first?.groupName, group.name)
        let loadedCalls = await probe.counts()
        XCTAssertEqual(loadedCalls, [1, 1])
        scrollToBottom(view, window: window)
        try writeSnapshot(view, name: "actual-detail-manual-load-en")
    }

    func testActualDetailInvalidationCancelsPendingQueriesAndRejectsLateResults() async throws {
        for transition in DetailTransition.allCases {
            for failure in [false, true] {
                let group = asgInsightsGroup()
                let other = asgInsightsGroup(name: "other")
                let parent = await loadedParent(groups: [group, other])
                let templateGate = TestGate(), refreshGate = TestGate()
                let probe = DetailInsightsProbe(templateGate: templateGate, refreshGate: refreshGate, failure: failure)
                let insights = makeInsights(probe)
                let (view, window) = mountedDetail(parent, insights: insights)
                _ = try XCTUnwrap(insights.scope)
                _ = try XCTUnwrap(insights.group)
                insights.loadTemplateVersions()
                insights.loadInstanceRefreshes()
                await templateGate.waitForEntry()
                await refreshGate.waitForEntry()
                switch transition {
                case .clearSelection:
                    parent.selectedGroup = nil
                case .changeScope:
                    parent.configure(scope: asgServiceScope(profile: "other-profile"))
                case .changeGroup:
                    parent.selectedGroup = other
                case .disappear:
                    view.rootView = AnyView(EmptyView())
                }
                settle(view, window: window)
                XCTAssertFalse(insights.isTemplatesLoading)
                XCTAssertFalse(insights.isRefreshesLoading)
                if transition == .changeGroup {
                    XCTAssertEqual(insights.scope, parent.scope)
                    XCTAssertEqual(insights.group, other)
                } else {
                    XCTAssertNil(insights.scope)
                    XCTAssertNil(insights.group)
                }
                if transition == .changeScope {
                    parent.loadIfNeeded()
                    await parent.waitForLoading()
                    parent.selectedGroup = group
                    await parent.waitForDetails()
                    settle(view, window: window)
                    XCTAssertEqual(insights.scope, parent.scope)
                    XCTAssertEqual(insights.group, group)
                }
                await templateGate.open()
                await refreshGate.open()
                await probe.waitForCompletion()
                settle(view, window: window)
                let cancellations = await probe.cancellations()
                XCTAssertEqual(cancellations, [true, true])
                XCTAssertTrue(insights.templateVersions.isEmpty)
                XCTAssertTrue(insights.instanceRefreshes.isEmpty)
                XCTAssertNil(insights.templatesError)
                XCTAssertNil(insights.refreshesError)
                let calls = await probe.counts()
                XCTAssertEqual(calls, [1, 1])
                window.close()
            }
        }
    }

    func testTemplateAliasesAndRefreshFailureDetailsRenderInNarrowPanes() async throws {
        let reference = ASGLaunchTemplate(templateID: asgInsightsTemplate.templateID, name: "web-template", version: "$Default")
        let group = asgInsightsGroup(template: reference)
        let version = ASGTemplateVersion(reference: reference, templateID: "lt-0123456789abcdef0", templateName: "web-template",
            version: 4, isDefault: true, description: String(repeating: "Production launch template 生产启动模板。", count: 5),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), createdBy: "arn:aws:iam::111122223333:role/ReadOnly",
            imageID: "resolve:ssm:/production/ami/latest", instanceType: "m7g.large", keyName: nil,
            securityGroupIDs: ["sg-0123456789abcdef0"], instanceProfileARN: nil, instanceProfileName: nil,
            ebsOptimized: true, detailedMonitoring: false)
        let refresh = ASGInstanceRefresh(id: "refresh-0123456789abcdef", groupName: group.name, status: "Failed",
            percentageComplete: 25, instancesRemaining: 3, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            statusReason: String(repeating: "Insufficient capacity in selected zone. 所选可用区容量不足。", count: 8), strategy: "Rolling")
        let vm = AutoScalingInsightsViewModel(templateLoader: { _, _, _ in [version] }, refreshLoader: { _, _ in [refresh] })
        vm.configure(scope: asgServiceScope(), group: group)
        vm.loadTemplateVersions()
        vm.loadInstanceRefreshes()
        await vm.waitForLoading()
        for (language, scheme) in [("en", ColorScheme.light), ("zh-Hans", ColorScheme.dark)] {
            try snapshot(ScrollView { AutoScalingInsightsView(vm: vm).padding(16) }, name: "templates-\(language)", language: language, scheme: scheme)
            try snapshot(ScrollView { AutoScalingInsightsView(vm: vm).padding(16) }, name: "refreshes-\(language)", language: language, scheme: scheme, scrollToBottom: true)
        }
    }

    func testUnknownFieldsAndIndependentErrorsRender() async throws {
        let vm = AutoScalingInsightsViewModel(templateLoader: { _, _, _ in [asgInsightsModel()] }, refreshLoader: { _, _ in
            throw AutoScalingInsightsError.refreshesPermission
        })
        vm.configure(scope: asgServiceScope(), group: asgInsightsGroup())
        vm.loadTemplateVersions()
        vm.loadInstanceRefreshes()
        await vm.waitForLoading()
        XCTAssertNil(vm.templateVersions.first?.isDefault)
        XCTAssertNotNil(vm.refreshesError)
        try snapshot(ScrollView { AutoScalingInsightsView(vm: vm).padding(16) }, name: "unknown-partial-zh-Hans",
                     language: "zh-Hans", scheme: .dark, scrollToBottom: true)
    }

    func testNoReferencesAndNoRefreshesRenderAsEmptyState() async throws {
        let vm = AutoScalingInsightsViewModel(templateLoader: { _, _, _ in [] }, refreshLoader: { _, _ in [] })
        vm.configure(scope: asgServiceScope(), group: asgInsightsGroup(template: nil))
        vm.loadTemplateVersions()
        vm.loadInstanceRefreshes()
        await vm.waitForLoading()
        try snapshot(ScrollView { AutoScalingInsightsView(vm: vm).padding(16) }, name: "empty-en", language: "en", scheme: .light)
    }

    private func loadedParent(groups: [ASGGroup]) async -> AutoScalingViewModel {
        let vm = AutoScalingViewModel(groupLoader: { _ in groups }, policyLoader: { _, _ in [] }, activityLoader: { _, _ in [] })
        vm.configure(scope: asgServiceScope())
        vm.loadIfNeeded()
        await vm.waitForLoading()
        vm.selectedGroup = groups.first
        await vm.waitForDetails()
        return vm
    }

    private func makeInsights(_ probe: DetailInsightsProbe) -> AutoScalingInsightsViewModel {
        AutoScalingInsightsViewModel(templateLoader: { try await probe.templates(reference: $2) },
            refreshLoader: { try await probe.refreshes(group: $1) })
    }

    private func mountedDetail(_ vm: AutoScalingViewModel, insights: AutoScalingInsightsViewModel) -> (NSHostingView<AnyView>, NSWindow) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let width: CGFloat = 480, height: CGFloat = 900
        let root = AnyView(AutoScalingGroupDetailView(vm: vm, insightsVM: insights)
            .frame(width: width, height: height).background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: "en")))
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        settle(view, window: window)
        return (view, window)
    }

    private func insightButtons(in view: NSView) throws -> (templates: NSView, refreshes: NSView) {
        let scroll = try XCTUnwrap(descendants(view).first { $0 is NSScrollView } as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        // The headless host omits SwiftUI AX nodes. Bordered buttons have native
        // focus-ring views, as in the EC2/S3 presentation fixtures; the scroll
        // document excludes the unrelated refresh button in the detail header.
        let buttons = descendants(document).filter {
            String(describing: type(of: $0)) == "_FocusRingView" && !$0.isHiddenOrHasHiddenAncestor
        }.sorted {
            let first = $0.convert($0.bounds, to: document)
            let second = $1.convert($1.bounds, to: document)
            return document.isFlipped ? first.minY < second.minY : first.maxY > second.maxY
        }
        XCTAssertEqual(buttons.count, 2)
        return (try XCTUnwrap(buttons.first), try XCTUnwrap(buttons.last))
    }

    private func press(_ button: NSView, in view: NSView, window: NSWindow, index: Int) throws {
        XCTAssertTrue(button.window === window)
        let frame = button.convert(button.bounds, to: view)
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertTrue(view.bounds.contains(frame))
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: index * 2 + 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.001, windowNumber: window.windowNumber,
            context: nil, eventNumber: index * 2 + 2, clickCount: 1, pressure: 0))
        // Queue the release before dispatch: native buttons can synchronously
        // track mouseDown until they receive mouseUp from the application queue.
        NSApplication.shared.postEvent(up, atStart: true)
        NSApplication.shared.postEvent(down, atStart: true)
        for _ in 0..<2 {
            guard let event = NSApplication.shared.nextEvent(matching: [.leftMouseDown, .leftMouseUp],
                until: Date(), inMode: .default, dequeue: true) else { break }
            guard event.windowNumber == window.windowNumber,
                  event.eventNumber == down.eventNumber || event.eventNumber == up.eventNumber else {
                NSApplication.shared.postEvent(event, atStart: true)
                XCTFail("Unexpected mouse event in presentation fixture")
                break
            }
            NSApplication.shared.sendEvent(event)
        }
    }

    private func scrollToBottom(_ view: NSView, window: NSWindow) {
        guard let scroll = descendants(view).first(where: { $0 is NSScrollView }) as? NSScrollView,
              let document = scroll.documentView else { return }
        let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? maximum : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(view, window: window)
    }

    private func snapshot<Content: View>(_ content: Content, name: String, language: String,
                                        scheme: ColorScheme, scrollToBottom: Bool = false) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let width: CGFloat = 480, height: CGFloat = 900
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
        settle(view, window: window)
        if scrollToBottom {
            let scroll = try XCTUnwrap(descendants(view).first { $0 is NSScrollView } as? NSScrollView)
            let document = try XCTUnwrap(scroll.documentView)
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? maximum : 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(view, window: window)
        }
        XCTAssertLessThanOrEqual(view.fittingSize.width, width)
        try writeSnapshot(view, name: name)
    }

    private func writeSnapshot(_ view: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/service-submodules/screenshots/asg")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func settle(_ view: NSView, window: NSWindow) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        view.displayIfNeeded()
    }
    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}

private enum DetailTransition: CaseIterable { case clearSelection, changeScope, changeGroup, disappear }

private actor DetailInsightsProbe {
    private let templateGate: TestGate?
    private let refreshGate: TestGate?
    private let failure: Bool
    private var templateCalls = 0, refreshCalls = 0
    private var templateCancelled = false, refreshCancelled = false
    private var completed = 0
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    init(templateGate: TestGate? = nil, refreshGate: TestGate? = nil, failure: Bool = false) {
        self.templateGate = templateGate; self.refreshGate = refreshGate; self.failure = failure
    }

    func counts() -> [Int] { [templateCalls, refreshCalls] }
    func cancellations() -> [Bool] { [templateCancelled, refreshCancelled] }
    func waitForCompletion() async {
        if completed == 2 { return }
        await withCheckedContinuation { completionWaiters.append($0) }
    }
    func templates(reference: ASGLaunchTemplate) async throws -> [ASGTemplateVersion] {
        templateCalls += 1
        await templateGate?.wait()
        templateCancelled = Task.isCancelled
        finish()
        if failure { throw AutoScalingInsightsError.templatesPermission }
        return [asgInsightsModel(reference: reference)]
    }
    func refreshes(group: ASGGroup) async throws -> [ASGInstanceRefresh] {
        refreshCalls += 1
        await refreshGate?.wait()
        refreshCancelled = Task.isCancelled
        finish()
        if failure { throw AutoScalingInsightsError.refreshesPermission }
        return [asgInsightsRefresh(group: group.name)]
    }
    private func finish() {
        completed += 1
        if completed == 2 {
            completionWaiters.forEach { $0.resume() }
            completionWaiters = []
        }
    }
}
