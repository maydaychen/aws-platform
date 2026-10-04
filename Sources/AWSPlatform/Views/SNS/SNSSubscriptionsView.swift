import AppKit
import SwiftUI

struct SNSSubscriptionsView: View {
    @Environment(\.locale) private var locale
    let topic: SNSTopic
    @ObservedObject var vm: SNSViewModel
    @State private var endpointVisibility: SNSEndpointRevealState

    init(topic: SNSTopic, vm: SNSViewModel, endpointVisibility: SNSEndpointRevealState = SNSEndpointRevealState()) {
        self.topic = topic
        self.vm = vm
        _endpointVisibility = State(initialValue: endpointVisibility)
    }

    private var isCurrentSelection: Bool { vm.selectedTopic?.arn == topic.arn }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Endpoints stay hidden until revealed. Subscriber owners can be different accounts; only this topic is queried.", locale: locale))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isCurrentSelection && vm.isSubscriptionsLoading {
                ProgressView(L10n.text("Loading subscriptions…", locale: locale)).controlSize(.small)
            } else if isCurrentSelection, let error = vm.subscriptionsError {
                NoticeBanner(message: error)
            } else if isCurrentSelection && !vm.subscriptions.isEmpty {
                Text(L10n.format("%@ subscriptions", String(vm.subscriptions.count), locale: locale)).font(.caption).foregroundColor(.secondary)
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.subscriptions) { subscription in subscriptionRow(subscription) }
                }
            } else {
                Text(L10n.text("No subscriptions returned.", locale: locale)).font(.callout).foregroundColor(.secondary)
            }
        }
        .onChange(of: topic.arn) { _ in endpointVisibility.clear() }
        .onChange(of: vm.scope) { _ in endpointVisibility.clear() }
        .onChange(of: vm.subscriptions) { _ in endpointVisibility.clear() }
    }

    private func subscriptionRow(_ subscription: SNSSubscription) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(subscription.protocolName.map { SNSDisplay.returned($0, locale: locale) } ?? L10n.text("Unknown protocol", locale: locale))
                    .font(.headline)
                Spacer(minLength: 0)
                Text(L10n.text(subscription.status, locale: locale)).font(.caption).foregroundColor(statusColor(subscription.status))
            }
            Text(L10n.format("Owner: %@", subscription.owner.map { SNSDisplay.returned($0, locale: locale) } ?? L10n.text("Not returned", locale: locale), locale: locale))
                .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            Text(subscription.arn.map { SNSDisplay.returned($0, locale: locale) } ?? L10n.text("Subscription ARN not returned", locale: locale))
                .font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            endpoint(subscription)
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func endpoint(_ subscription: SNSSubscription) -> some View {
        if let endpoint = subscription.endpoint {
            let isRevealed = endpointVisibility.isRevealed(subscription, scope: vm.scope, topicARN: topic.arn)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(L10n.text("Endpoint", locale: locale)).font(.caption).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Button(L10n.text(isRevealed ? "Hide" : "Reveal", locale: locale)) {
                        endpointVisibility.toggle(subscription, scope: vm.scope, topicARN: topic.arn)
                    }
                    .disabled(vm.scope == nil)
                    if isRevealed {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(endpoint, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .help(L10n.text("Copy visible endpoint", locale: locale)).accessibilityLabel(L10n.text("Copy visible endpoint", locale: locale))
                    }
                }
                if isRevealed {
                    Text(SNSDisplay.returned(endpoint, locale: locale)).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(L10n.text("Hidden", locale: locale), systemImage: "eye.slash").font(.callout).foregroundColor(.secondary)
                }
            }
        } else {
            Text(L10n.text("Endpoint not returned", locale: locale)).font(.caption).foregroundColor(.secondary)
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "Confirmed": return .green
        case "Pending confirmation": return .orange
        default: return .secondary
        }
    }
}

struct SNSEndpointRevealState {
    private var scope: SNSScope?
    private var topicARN: String?
    private var endpoints: [String: String] = [:]

    func isRevealed(_ subscription: SNSSubscription, scope: SNSScope?, topicARN: String) -> Bool {
        guard let scope, let endpoint = subscription.endpoint else { return false }
        return self.scope == scope && self.topicARN == topicARN && subscription.topicARN == topicARN
            && endpoints[subscription.id] == endpoint
    }

    mutating func toggle(_ subscription: SNSSubscription, scope: SNSScope?, topicARN: String) {
        guard let scope, let endpoint = subscription.endpoint, subscription.topicARN == topicARN else { return }
        if self.scope != scope || self.topicARN != topicARN {
            clear()
            self.scope = scope
            self.topicARN = topicARN
        }
        if endpoints[subscription.id] == endpoint { endpoints.removeValue(forKey: subscription.id) }
        else { endpoints[subscription.id] = endpoint }
    }

    mutating func clear() {
        endpoints = [:]
        scope = nil
        topicARN = nil
    }
}
