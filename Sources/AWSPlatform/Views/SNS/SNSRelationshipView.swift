import AppKit
import SwiftUI

struct SNSRelationshipView: View {
    let topic: SNSTopic
    @ObservedObject var snsVM: SNSViewModel
    @ObservedObject var vm: SNSRelationshipViewModel
    let onOpenResource: (SNSRelatedResource) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var endpointVisibility: SNSEndpointRevealState
    @State private var expandedNodeIDs: Set<String>
    @State private var isAboutExpanded = false

    init(topic: SNSTopic, snsVM: SNSViewModel, vm: SNSRelationshipViewModel,
         endpointVisibility: SNSEndpointRevealState = SNSEndpointRevealState(),
         expandedNodeIDs: Set<String> = [],
         onOpenResource: @escaping (SNSRelatedResource) -> Void) {
        self.topic = topic
        self.snsVM = snsVM
        self.vm = vm
        self.onOpenResource = onOpenResource
        _endpointVisibility = State(initialValue: endpointVisibility)
        _expandedNodeIDs = State(initialValue: expandedNodeIDs)
    }

    private var activeScope: SNSScope? {
        guard snsVM.selectedTopic == topic else { return nil }
        return snsVM.scope
    }

    private var hasCurrentUpstream: Bool {
        activeScope != nil && vm.scope == activeScope && vm.topic == topic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let scope = activeScope {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(scope.profileName) · \(scope.accountID) · \(scope.region)")
                        .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("About this view", isExpanded: $isAboutExpanded) {
                        Text("Configuration links, not message delivery traces. The upstream check covers CloudWatch Metric and Composite alarm actions in this profile and region. S3 notifications, Lambda destinations and application Publish calls are not scanned. Subscriptions are reused from topic details; refresh them there. Raw endpoints stay hidden until revealed.")
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)
                    }
                    .font(.caption)
                }
                .padding(16)
                Divider()
                ScrollView {
                    HStack(alignment: .top, spacing: 12) {
                        upstreamColumn
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        arrow
                        topicColumn
                            .frame(width: 210, alignment: .topLeading)
                        arrow
                        downstreamColumn(scope)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(16)
                }
            } else {
                EmptyStateView(text: "The selected topic or profile changed. Close this view and open it again from the current topic.", icon: "person.crop.circle.badge.questionmark")
            }
        }
        .frame(minWidth: 960, idealWidth: 1100, minHeight: 600, idealHeight: 700)
        .onAppear { vm.load(scope: activeScope, topic: topic) }
        .onDisappear {
            resetExpandedDetails()
            vm.reset()
        }
        .onChange(of: activeScope) { _ in resetForSelectionChange() }
        .onChange(of: topic) { _ in resetForSelectionChange() }
        .onChange(of: snsVM.subscriptions) { _ in resetExpandedDetails() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("调用链查看", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.title2.weight(.semibold))
            Spacer()
            Button("Refresh upstream", action: vm.refresh)
                .disabled(!hasCurrentUpstream || vm.isLoading)
                .help("Read CloudWatch alarm configuration again. Subscription data is reused from topic details.")
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.headline).foregroundColor(.secondary)
            .frame(width: 16).padding(.top, 48)
            .accessibilityHidden(true)
    }

    private var upstreamColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("CloudWatch alarms", systemImage: "bell.badge").font(.headline)
            if !hasCurrentUpstream {
                relationshipMessage("Upstream check is not available for this selection.")
            } else if vm.isLoading {
                ProgressView("Checking alarm actions…").controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            } else if let error = vm.error {
                NoticeBanner(message: error)
            } else if vm.hasLoaded && vm.sources.isEmpty {
                relationshipMessage("No matching CloudWatch alarm actions were found in this scan. Other publishing sources may exist.")
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.sources) { source in sourceCard(source) }
                }
            }
        }
    }

    private func sourceCard(_ source: SNSAlarmRelationship) -> some View {
        DisclosureGroup(isExpanded: expansion("alarm:" + source.alarm.arn)) {
            VStack(alignment: .leading, spacing: 8) {
                Button("Open alarm") { open(source.target) }
                    .disabled(!source.target.isValid(in: activeScope))
                Text("\(source.alarm.kind.title) · \(source.triggers.joined(separator: ", "))")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AlarmStateLabel(state: source.alarm.state).font(.caption)
                Text("Actions enabled: \(AlarmDisplay.boolean(source.alarm.actionsEnabled))")
                    .font(.caption).foregroundColor(source.alarm.actionsEnabled == false ? .orange : .secondary)
                if source.alarm.actionsEnabled == false {
                    Text("Configured link; alarm actions are disabled.")
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(source.alarm.configuration.filter { $0.label.localizedCaseInsensitiveContains("suppress") }) { property in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(property.label).font(.caption).foregroundColor(.secondary)
                        Text(property.value).font(.caption).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(source.alarm.arn).font(.caption.monospaced()).foregroundColor(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 10)
        } label: {
            nodeLabel(source.alarm.name, nodeID: "alarm:" + source.alarm.arn,
                      symbol: "bell.badge", accent: .purple)
        }
        .relationshipCard(accent: .purple, isExpanded: expandedNodeIDs.contains("alarm:" + source.alarm.arn))
    }

    private var topicColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("SNS Topic", systemImage: "dot.radiowaves.left.and.right").font(.headline)
            DisclosureGroup(isExpanded: expansion("topic:" + topic.arn)) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(topic.kind.title).font(.caption).foregroundColor(.secondary)
                    Text(topic.arn).font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Only this topic's subscriptions are shown.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.top, 10)
            } label: {
                nodeLabel(topic.name, nodeID: "topic:" + topic.arn,
                          symbol: "dot.radiowaves.left.and.right", accent: .orange)
            }
            .relationshipCard(accent: .orange, isExpanded: expandedNodeIDs.contains("topic:" + topic.arn))
        }
    }

    private func downstreamColumn(_ scope: SNSScope) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Subscriptions", systemImage: "arrow.triangle.branch").font(.headline)
            if snsVM.isSubscriptionsLoading {
                ProgressView("Loading subscriptions…").controlSize(.small)
            } else if snsVM.subscriptionsError != nil {
                NoticeBanner(message: "Subscriptions could not be loaded. Check the topic's permissions and connection, then refresh its details. Upstream results remain independent.")
            } else if snsVM.subscriptions.isEmpty {
                relationshipMessage("No subscriptions were returned for this topic.")
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(snsVM.subscriptions) { subscription in subscriptionCard(subscription, scope: scope) }
                }
            }
        }
    }

    private func subscriptionCard(_ subscription: SNSSubscription, scope: SNSScope) -> some View {
        let target = SNSRelationshipMapping.lambdaTarget(subscription, scope: scope, topic: topic)
        return DisclosureGroup(isExpanded: expansion("subscription:" + subscription.id)) {
            VStack(alignment: .leading, spacing: 8) {
                if let target {
                    Button("Open Lambda function") { open(target) }
                        .disabled(!target.isValid(in: activeScope))
                    if let qualifier = target.qualifier {
                        Text("Alias or version: \(qualifier)").font(.caption).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(SNSRelationshipMapping.navigationNote(subscription, scope: scope, topic: topic))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Text(subscription.protocolName.map(SNSDisplay.returned) ?? "Unknown protocol").font(.caption)
                Text(subscription.status).font(.caption)
                    .foregroundColor(subscription.status == "Pending confirmation" ? .orange : .secondary)
                Text("Owner: \(subscription.owner.map(SNSDisplay.returned) ?? "Not returned")")
                    .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subscription.arn.map(SNSDisplay.returned) ?? "Subscription ARN not returned")
                    .font(.caption.monospaced()).foregroundColor(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                subscriptionEndpoint(subscription, scope: scope)
            }
            .padding(.top, 10)
        } label: {
            nodeLabel(target?.resourceID ?? subscriptionTitle(subscription), nodeID: "subscription:" + subscription.id,
                      symbol: subscription.protocolName == "lambda" ? "function" : "arrow.up.right",
                      accent: .blue)
        }
        .relationshipCard(accent: .blue, isExpanded: expandedNodeIDs.contains("subscription:" + subscription.id))
    }

    @ViewBuilder
    private func subscriptionEndpoint(_ subscription: SNSSubscription, scope: SNSScope) -> some View {
        if let endpoint = subscription.endpoint {
            let revealed = endpointVisibility.isRevealed(subscription, scope: scope, topicARN: topic.arn)
            HStack(spacing: 8) {
                Label(revealed ? "Endpoint" : "Endpoint hidden", systemImage: revealed ? "eye" : "eye.slash")
                    .font(.caption).foregroundColor(.secondary)
                Spacer(minLength: 0)
                Button(revealed ? "Hide" : "Reveal") {
                    endpointVisibility.toggle(subscription, scope: activeScope, topicARN: topic.arn)
                }
            }
            if revealed {
                Text(SNSDisplay.returned(endpoint)).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy endpoint") {
                    guard endpointVisibility.isRevealed(subscription, scope: activeScope, topicARN: topic.arn) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(endpoint, forType: .string)
                }
            }
        } else {
            Text("Endpoint not returned").font(.caption).foregroundColor(.secondary)
        }
    }

    private func relationshipMessage(_ message: String) -> some View {
        Text(message).font(.callout).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .relationshipCard()
    }

    private func open(_ resource: SNSRelatedResource) {
        guard resource.isValid(in: activeScope) else { return }
        onOpenResource(resource)
    }

    private func subscriptionTitle(_ subscription: SNSSubscription) -> String {
        switch subscription.protocolName {
        case "email": return "Email subscription"
        case "email-json": return "Email JSON subscription"
        case "sms": return "SMS subscription"
        case "sqs": return "SQS subscription"
        case "http": return "HTTP subscription"
        case "https": return "HTTPS subscription"
        case "application": return "Application subscription"
        case "firehose": return "Firehose subscription"
        case "lambda": return "Lambda subscription"
        default: return "Subscription"
        }
    }

    private func expansion(_ nodeID: String) -> Binding<Bool> {
        Binding(
            get: { expandedNodeIDs.contains(nodeID) },
            set: { expanded in
                if expanded { expandedNodeIDs.insert(nodeID) }
                else { expandedNodeIDs.remove(nodeID) }
            }
        )
    }

    private func nodeLabel(_ title: String, nodeID: String, symbol: String, accent: Color) -> some View {
        Button {
            if expandedNodeIDs.contains(nodeID) { expandedNodeIDs.remove(nodeID) }
            else { expandedNodeIDs.insert(nodeID) }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accent)
                    .frame(width: 30, height: 30)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(accent.opacity(0.12)))
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expandedNodeIDs.contains(nodeID) ? "Expanded" : "Collapsed")
        .accessibilityHint("Show or hide node details")
    }

    private func resetExpandedDetails() {
        expandedNodeIDs = []
        isAboutExpanded = false
        endpointVisibility.clear()
    }

    private func resetForSelectionChange() {
        resetExpandedDetails()
        vm.reset()
    }
}

private extension View {
    func relationshipCard(accent: Color? = nil, isExpanded: Bool = false) -> some View {
        modifier(SNSRelationshipCardStyle(accent: accent, isExpanded: isExpanded))
    }
}

private struct SNSRelationshipCardStyle: ViewModifier {
    let accent: Color?
    let isExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var highlighted: Bool { accent != nil && (isHovered || isExpanded) }
    private var tint: Color { accent ?? .clear }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let isDark = colorScheme == .dark
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                shape.fill(Color(nsColor: .controlBackgroundColor))
                shape.fill(LinearGradient(
                    colors: [tint.opacity(highlighted ? 0.09 : 0.035), .clear],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(
                    colors: [Color.primary.opacity(isDark ? 0.16 : 0.07), Color.primary.opacity(0.035)],
                    startPoint: .top, endPoint: .bottom
                ))
                shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.48) : tint.opacity(highlighted ? 0.36 : 0.12))
            }
            .shadow(color: .black.opacity(isDark ? 0.18 : (highlighted ? 0.09 : 0.045)),
                    radius: highlighted ? 9 : 5, x: 0, y: highlighted ? 4 : 2)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: highlighted)
            .onHover { isHovered = $0 }
    }
}
