import AppKit
import SwiftUI
import Vision
import XCTest
@testable import AWSPlatform

@MainActor
final class SNSRelationshipPresentationTests: XCTestCase {
    func testActualRelationshipCardsRetainContentAcrossLanguagesAndAppearances() async throws {
        let scope = SNSScope(
            profile: AWSProfile(name: "offline-preview", region: "us-east-1", ssoStartURL: nil,
                                ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil),
            identity: AWSIdentity(account: "111122223333", arn: "arn:aws:sts::111122223333:assumed-role/ReadOnly/test", userID: "test"),
            region: "us-east-1", paths: AWSConfigurationPaths(environment: [:]))
        let topicName = String(repeating: "production-notifications-", count: 5)
        let topic = SNSTopic(arn: "arn:aws:sns:us-east-1:111122223333:\(topicName)", name: topicName)
        let alarmName = String(repeating: "service-latency-", count: 8)
        let alarm = CloudWatchAlarm(arn: "arn:aws:cloudwatch:us-east-1:111122223333:alarm:\(alarmName)",
                                   name: alarmName, kind: .metric, state: "ALARM", actionsEnabled: true,
                                   alarmActions: [topic.arn])
        let endpoint = "arn:aws:lambda:us-east-1:111122223333:function:notification-processor-production:LIVE"
        let subscription = SNSSubscription(id: "offline-subscription", arn: topic.arn + ":12345678-1234-1234-1234-123456789012",
                                           protocolName: "lambda", endpoint: endpoint, owner: scope.accountID,
                                           topicARN: topic.arn, status: "Confirmed")
        for language in ["en", "zh-Hans"] {
            for scheme in [ColorScheme.light, .dark] {
                let probe = SNSPresentationProbe()
                let sns = SNSViewModel(listLoader: { _ in [topic] }, attributeLoader: { _, _ in [:] },
                                       tagLoader: { _, _ in [:] }, subscriptionLoader: { _, _ in [subscription] })
                sns.configure(scope: scope)
                await sns.loadTopics()
                sns.selectedTopic = topic
                await sns.waitForDetails()
                let relationships = SNSRelationshipViewModel(loader: { _ in await probe.load(alarm) })
                relationships.load(scope: scope, topic: topic)
                await relationships.waitForLoad()
                var revealed = SNSEndpointRevealState()
                revealed.toggle(subscription, scope: scope, topicARN: topic.arn)
                var opened: [SNSRelatedResource] = []
                let content = SNSRelationshipView(topic: topic, snsVM: sns, vm: relationships,
                    endpointVisibility: revealed,
                    expandedNodeIDs: ["alarm:" + alarm.arn, "topic:" + topic.arn, "subscription:" + subscription.id],
                    onOpenResource: { opened.append($0) })
                let (view, window) = mount(content, language: language, scheme: scheme)
                defer { window.close(); sns.reset(); relationships.reset() }
                await settle()
                let text = values(view)
                for expected in [topic.arn, alarm.arn, endpoint, subscription.arn!] {
                    XCTAssertTrue(text.contains(expected), "The actual expanded native card lost \(expected)")
                }
                XCTAssertEqual(view.fittingSize.width, 1_100, accuracy: 1, "Long ARNs must fit the fixed sheet width")
                let name = "relationships-\(language)-\(scheme == .dark ? "dark" : "light")"
                let observations = try capture(view, window: window, name: name, language: language)
                let title = L10n.text("View relationships", locale: Locale(identifier: language))
                XCTAssertTrue(observations.contains { $0.topCandidates(1).first?.string.contains(title) == true },
                              "The native heading must remain visibly readable")
                if language == "en", scheme == .light {
                    try press("Open alarm", observations: observations, view: view, window: window)
                    try press("Open Lambda function", observations: observations, view: view, window: window)
                    await settle()
                    XCTAssertEqual(opened.map(\.service), [.alarms, .lambda])
                    XCTAssertEqual(opened.map(\.scope), [scope, scope])
                }
                let calls = await probe.count()
                XCTAssertEqual(calls, 1, "Mounting, restyling, and opening cards must reuse the upstream result")
            }
        }
    }

    private func mount(_ content: SNSRelationshipView, language: String, scheme: ColorScheme) -> (NSHostingView<AnyView>, NSWindow) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = content.frame(width: 1_100, height: 1_100, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, scheme)
        let view = NSHostingView(rootView: AnyView(root))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1_100, height: 1_100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.orderBack(nil)
        return (view, window)
    }

    private func capture(_ view: NSView, window: NSWindow, name: String, language: String) throws -> [VNRecognizedTextObservation] {
        let appearance = try XCTUnwrap(window.appearance)
        appearance.performAsCurrentDrawingAppearance {
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); view.displayIfNeeded()
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/audit-remediation/sns", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = language == "en" ? ["en-US"] : ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
        return request.results ?? []
    }

    private func press(_ title: String, observations: [VNRecognizedTextObservation], view: NSView, window: NSWindow) throws {
        let label = try XCTUnwrap(observations.first { $0.topCandidates(1).first?.string == title })
        let bounds = label.boundingBox
        let point = view.convert(NSPoint(x: bounds.midX * view.bounds.width,
                                         y: (view.isFlipped ? 1 - bounds.midY : bounds.midY) * view.bounds.height), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.001, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        NSApplication.shared.postEvent(up, atStart: true)
        window.sendEvent(down); window.sendEvent(up)
    }

    private func values(_ view: NSView) -> [String] {
        var queue: [NSObject] = [view]
        var seen: Set<ObjectIdentifier> = []
        var result: [String] = []
        while !queue.isEmpty && seen.count < 2_000 {
            let node = queue.removeFirst()
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            for key in ["accessibilityValue", "accessibilityLabel"] {
                let selector = NSSelectorFromString(key)
                if node.responds(to: selector), let text = node.perform(selector)?.takeUnretainedValue() as? String { result.append(text) }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: children), let values = node.perform(children)?.takeUnretainedValue() as? [NSObject] { queue += values }
            if let native = node as? NSView { queue += native.subviews }
        }
        return result
    }

    private func settle() async { for _ in 0..<8 { try? await Task.sleep(for: .milliseconds(15)) } }
}

private actor SNSPresentationProbe {
    private var calls = 0
    func load(_ alarm: CloudWatchAlarm) -> [CloudWatchAlarm] { calls += 1; return [alarm] }
    func count() -> Int { calls }
}
