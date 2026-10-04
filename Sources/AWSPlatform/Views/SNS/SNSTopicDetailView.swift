import AppKit
import SwiftUI

struct SNSTopicDetailView: View {
    @Environment(\.locale) private var locale
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", configuration = "Configuration", subscriptions = "Subscriptions"
        var id: Self { self }
    }

    let topic: SNSTopic
    @ObservedObject var vm: SNSViewModel
    let onViewRelationships: (() -> Void)?
    @State private var selectedTab: Tab

    init(topic: SNSTopic, vm: SNSViewModel, tab: Tab = .overview, onViewRelationships: (() -> Void)? = nil) {
        self.topic = topic
        self.vm = vm
        self.onViewRelationships = onViewRelationships
        _selectedTab = State(initialValue: tab)
    }

    private var isCurrentSelection: Bool { vm.selectedTopic?.arn == topic.arn }
    private var attributes: [String: String] { isCurrentSelection ? vm.attributes : [:] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker(L10n.text("Section", locale: locale), selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in Text(L10n.text(tab.rawValue, locale: locale)).tag(tab) }
            }
            .labelsHidden().pickerStyle(.segmented).padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .overview: overview
                    case .configuration: configuration
                    case .subscriptions: SNSSubscriptionsView(topic: topic, vm: vm)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .onChange(of: topic.arn) { _ in selectedTab = .overview }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(topic.name).font(.title2.weight(.semibold)).lineLimit(3)
                    .textSelection(.enabled).help(topic.name)
                Spacer(minLength: 0)
                Button(action: vm.refreshDetails) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!isCurrentSelection || vm.isAttributesLoading || vm.isTagsLoading || vm.isSubscriptionsLoading)
                .help(L10n.text("Refresh topic attributes, tags and subscriptions", locale: locale))
                .accessibilityLabel(L10n.text("Refresh topic details", locale: locale))
            }
            HStack(spacing: 8) {
                Text(L10n.format("%@ topic · Read only", L10n.text(topic.kind.title, locale: locale), locale: locale)).font(.caption).foregroundColor(.secondary)
                Spacer(minLength: 0)
                if let onViewRelationships {
                    Button(action: onViewRelationships) {
                        Label(L10n.text("View relationships", locale: locale), systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .disabled(!isCurrentSelection || vm.scope == nil)
                    .help(L10n.text("Inspect CloudWatch alarm actions and this topic's subscriptions", locale: locale))
                }
            }
            HStack(alignment: .top, spacing: 6) {
                Text(topic.arn).font(.caption.monospaced()).foregroundColor(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(topic.arn, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help(L10n.text("Copy topic ARN", locale: locale)).accessibilityLabel(L10n.text("Copy topic ARN", locale: locale))
            }
        }
        .padding(16)
    }

    private var overview: some View {
        Group {
            attributeStatus
            DetailGrid(items: [
                ("Display name", attribute("DisplayName")),
                ("Owner", attribute("Owner")),
                ("Confirmed subscriptions", attribute("SubscriptionsConfirmed")),
                ("Pending subscriptions", attribute("SubscriptionsPending")),
                ("Deleted subscriptions", attribute("SubscriptionsDeleted"))
            ])
            DetailSectionTitle(title: "Tags")
            if isCurrentSelection && vm.isTagsLoading {
                ProgressView(L10n.text("Loading tags…", locale: locale)).controlSize(.small)
            } else if isCurrentSelection, let error = vm.tagsError {
                NoticeBanner(message: error)
            } else if isCurrentSelection && !vm.tags.isEmpty {
                DetailKeyValueRows(values: vm.tags)
            } else {
                Text(L10n.text("No tags returned.", locale: locale)).font(.callout).foregroundColor(.secondary)
            }
        }
    }

    private var configuration: some View {
        Group {
            attributeStatus
            DetailGrid(items: [
                ("Encryption key", attribute("KmsMasterKeyId")),
                ("FIFO topic", attribute("FifoTopic")),
                ("Content-based deduplication", attribute("ContentBasedDeduplication")),
                ("FIFO throughput scope", attribute("FifoThroughputScope")),
                ("Tracing", attribute("TracingConfig")),
                ("Signature version", attribute("SignatureVersion"))
            ])
            ForEach(Self.policyKeys, id: \.self) { key in
                if let value = attributes[key] {
                    DisclosureGroup(L10n.text(key, locale: locale)) {
                        SNSTextBlock(text: SNSDisplay.returned(value, locale: locale), monospaced: true)
                            .padding(.top, 8)
                    }
                    .font(.callout)
                }
            }
            if !otherAttributes.isEmpty {
                DetailSectionTitle(title: "Other returned attributes")
                DetailKeyValueRows(values: otherAttributes)
            }
        }
    }

    @ViewBuilder
    private var attributeStatus: some View {
        if isCurrentSelection && vm.isAttributesLoading {
            ProgressView(L10n.text("Loading attributes…", locale: locale)).controlSize(.small)
        } else if isCurrentSelection, let error = vm.attributesError {
            NoticeBanner(message: error)
        }
    }

    private func attribute(_ key: String) -> String {
        if isCurrentSelection && vm.isAttributesLoading { return L10n.text("Loading…", locale: locale) }
        return attributes[key].map { SNSDisplay.returned($0, locale: locale) } ?? L10n.text("Not returned", locale: locale)
    }

    private static let policyKeys = ["Policy", "DeliveryPolicy", "EffectiveDeliveryPolicy", "ArchivePolicy"]
    private var otherAttributes: [String: String] {
        let shownKeys: Set<String> = Set(Self.policyKeys).union([
            "TopicArn", "DisplayName", "Owner", "SubscriptionsConfirmed", "SubscriptionsPending", "SubscriptionsDeleted",
            "KmsMasterKeyId", "FifoTopic", "ContentBasedDeduplication", "FifoThroughputScope", "TracingConfig", "SignatureVersion"
        ])
        return attributes.filter { !shownKeys.contains($0.key) }.mapValues { SNSDisplay.returned($0, locale: locale) }
    }
}

enum SNSDisplay {
    static func returned(_ value: String, locale: Locale = Locale(identifier: "en")) -> String {
        value.isEmpty ? L10n.text("(empty)", locale: locale) : value
    }
}

struct SNSTextBlock: View {
    let text: String
    var monospaced = false

    var body: some View {
        Text(text)
            .font(monospaced ? .system(.caption, design: .monospaced) : .callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}
