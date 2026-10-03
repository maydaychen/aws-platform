import AppKit
import SwiftUI

struct SNSRelationshipView: View {
    let topic: SNSTopic
    @ObservedObject var snsVM: SNSViewModel
    @ObservedObject var vm: SNSRelationshipViewModel
    let onOpenResource: (SNSRelatedResource) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var endpointVisibility: SNSEndpointRevealState

    init(topic: SNSTopic, snsVM: SNSViewModel, vm: SNSRelationshipViewModel,
         endpointVisibility: SNSEndpointRevealState = SNSEndpointRevealState(),
         onOpenResource: @escaping (SNSRelatedResource) -> Void) {
        self.topic = topic
        self.snsVM = snsVM
        self.vm = vm
        self.onOpenResource = onOpenResource
        _endpointVisibility = State(initialValue: endpointVisibility)
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
                    Text("Configuration links, not message delivery traces. The upstream check covers CloudWatch Metric and Composite alarm actions in this profile and region. S3 notifications, Lambda destinations and application Publish calls are not scanned.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
            endpointVisibility.clear()
            vm.reset()
        }
        .onChange(of: activeScope) { _ in resetForSelectionChange() }
        .onChange(of: topic) { _ in resetForSelectionChange() }
        .onChange(of: snsVM.subscriptions) { _ in endpointVisibility.clear() }
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
            Text("Configured action sources").font(.caption).foregroundColor(.secondary)
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
        VStack(alignment: .leading, spacing: 8) {
            Text(source.alarm.name).font(.headline).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
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
            Button("Open alarm") { open(source.target) }
                .disabled(!source.target.isValid(in: activeScope))
        }
        .relationshipCard()
    }

    private var topicColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("SNS Topic", systemImage: "dot.radiowaves.left.and.right").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                Text(topic.name).font(.headline).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(topic.kind.title).font(.caption).foregroundColor(.secondary)
                Text(topic.arn).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Only this topic's subscriptions are shown.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .relationshipCard()
        }
    }

    private func downstreamColumn(_ scope: SNSScope) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Subscriptions", systemImage: "arrow.triangle.branch").font(.headline)
            Text("Reused from topic details").font(.caption).foregroundColor(.secondary)
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
            Text("Endpoints are hidden by default. Refresh subscriptions from topic details.")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func subscriptionCard(_ subscription: SNSSubscription, scope: SNSScope) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subscription.protocolName.map(SNSDisplay.returned) ?? "Unknown protocol").font(.headline)
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
        .relationshipCard()
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
                Text(SNSRelationshipMapping.navigationNote(subscription, scope: scope, topic: topic))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let target = SNSRelationshipMapping.lambdaTarget(subscription, scope: scope, topic: topic) {
                    if let qualifier = target.qualifier {
                        Text("Alias or version: \(qualifier)").font(.caption).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Open Lambda function") {
                        guard endpointVisibility.isRevealed(subscription, scope: activeScope, topicARN: topic.arn) else { return }
                        open(target)
                    }
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

    private func resetForSelectionChange() {
        endpointVisibility.clear()
        vm.reset()
    }
}

private extension View {
    func relationshipCard() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08)))
    }
}
