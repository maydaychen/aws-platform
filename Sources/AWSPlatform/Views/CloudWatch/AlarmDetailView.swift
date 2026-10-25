import AppKit
import SwiftUI

struct AlarmDetailView: View {
    @Environment(\.locale) private var locale
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", configuration = "Configuration", actions = "Actions", history = "History"
        var id: Self { self }
    }

    let alarm: CloudWatchAlarm
    @ObservedObject var vm: AlarmViewModel
    let scope: SNSScope?
    let onOpenResource: (SNSRelatedResource) -> Void
    @State private var selectedTab: Tab

    init(alarm: CloudWatchAlarm, vm: AlarmViewModel, tab: Tab = .overview,
         scope: SNSScope? = nil, onOpenResource: @escaping (SNSRelatedResource) -> Void = { _ in }) {
        self.alarm = alarm
        self.vm = vm
        self.scope = scope
        self.onOpenResource = onOpenResource
        _selectedTab = State(initialValue: tab)
    }

    private var isCurrentSelection: Bool { vm.selectedAlarm?.arn == alarm.arn }

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
                    case .actions: actions
                    case .history: history
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .onChange(of: alarm.arn) { _ in selectedTab = .overview }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(alarm.name).font(.title2.weight(.semibold)).lineLimit(3)
                    .textSelection(.enabled).help(alarm.name)
                Spacer(minLength: 0)
                Button(action: vm.refreshDetails) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!isCurrentSelection || vm.isTagsLoading || vm.isHistoryLoading)
                .help(L10n.text("Refresh tags and the last 30 days of history", locale: locale))
                .accessibilityLabel(L10n.text("Refresh alarm details", locale: locale))
            }
            HStack(spacing: 10) {
                AlarmStateLabel(state: alarm.state)
                Text(L10n.text(alarm.kind.title, locale: locale)).foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .font(.caption)
            HStack(alignment: .top, spacing: 6) {
                Text(alarm.arn).font(.caption.monospaced()).foregroundColor(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(alarm.arn, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help(L10n.text("Copy alarm ARN", locale: locale)).accessibilityLabel(L10n.text("Copy alarm ARN", locale: locale))
            }
        }
        .padding(16)
    }

    private var overview: some View {
        Group {
            if let description = alarm.description, !description.isEmpty {
                Text(description).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DetailGrid(items: [
                ("State updated", AlarmDisplay.date(alarm.stateUpdatedAt, locale: locale)),
                ("State transitioned", AlarmDisplay.date(alarm.stateTransitionedAt, locale: locale)),
                ("Configuration updated", AlarmDisplay.date(alarm.configurationUpdatedAt, locale: locale)),
                ("Actions enabled", AlarmDisplay.boolean(alarm.actionsEnabled, locale: locale))
            ])
            DetailSectionTitle(title: "State reason")
            AlarmTextBlock(text: alarm.reason ?? L10n.text("No state reason returned.", locale: locale))
            if let data = alarm.reasonData, !data.isEmpty {
                DisclosureGroup(L10n.text("State reason data", locale: locale)) { AlarmTextBlock(text: data, monospaced: true) }
                    .font(.caption)
            }
            DetailSectionTitle(title: "Tags")
            tags
        }
    }

    @ViewBuilder
    private var tags: some View {
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

    private var configuration: some View {
        Group {
            if !alarm.configuration.isEmpty {
                DetailGrid(items: alarm.configuration.map { ($0.label, $0.value) })
            }
            if let rule = alarm.rule {
                DetailSectionTitle(title: "Composite rule")
                AlarmTextBlock(text: rule, monospaced: true)
            }
            if !alarm.metrics.isEmpty {
                DetailSectionTitle(title: "Metric configuration")
                Text(L10n.text("Configuration only. Metric values are not queried.", locale: locale))
                    .font(.caption).foregroundColor(.secondary)
                ForEach(alarm.metrics) { metric in AlarmMetricView(metric: metric) }
            } else if alarm.kind == .metric {
                Text(L10n.text("No metric configuration returned.", locale: locale)).font(.callout).foregroundColor(.secondary)
            }
            if alarm.configuration.isEmpty && alarm.rule == nil && alarm.metrics.isEmpty {
                Text(L10n.text("No alarm configuration returned.", locale: locale)).font(.callout).foregroundColor(.secondary)
            }
        }
    }

    private var actions: some View {
        Group {
            DetailGrid(items: [("Actions enabled", AlarmDisplay.boolean(alarm.actionsEnabled, locale: locale))])
            Text(L10n.text("Open SNS topics in the current profile and region. Other action targets are shown as configured; no notifications are sent.", locale: locale))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actionTargets("ALARM targets", targets: alarm.alarmActions)
            actionTargets("OK targets", targets: alarm.okActions)
            actionTargets("INSUFFICIENT_DATA targets", targets: alarm.insufficientDataActions)
        }
    }

    private func actionTargets(_ title: String, targets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailSectionTitle(title: title)
            if targets.isEmpty {
                Text(L10n.text("None configured", locale: locale)).font(.callout).foregroundColor(.secondary)
            } else {
                ForEach(Array(targets.enumerated()), id: \.offset) { _, target in
                    VStack(alignment: .leading, spacing: 6) {
                        AlarmTextBlock(text: target, monospaced: true)
                        if let scope, vm.scope == scope.alarmScope, isCurrentSelection,
                           SNSRelatedResource(scope: scope, service: .alarms, arn: alarm.arn) != nil,
                           let resource = SNSRelatedResource(scope: scope, service: .sns, arn: target) {
                            Button { onOpenResource(resource) } label: {
                                Label(L10n.text("Open SNS topic", locale: locale), systemImage: "arrow.up.forward.square")
                            }
                            .help(L10n.text("Open this topic in the current profile and region", locale: locale))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var history: some View {
        Text(L10n.text("Last 30 days · UTC · Most recent first", locale: locale))
            .font(.caption).foregroundColor(.secondary)
        if isCurrentSelection && vm.isHistoryLoading {
            ProgressView(L10n.text("Loading alarm history…", locale: locale)).controlSize(.small)
        } else if isCurrentSelection, let error = vm.historyError {
            NoticeBanner(message: error)
        } else if isCurrentSelection && !vm.history.isEmpty {
            ForEach(vm.history) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.type).font(.headline)
                    Text(AlarmDisplay.date(entry.timestamp, locale: locale)).font(.caption).foregroundColor(.secondary)
                    Text(entry.summary).font(.callout).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let contributor = entry.contributorID {
                        Text(L10n.format("Contributor: %@", contributor, locale: locale)).font(.caption).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let data = entry.data, !data.isEmpty {
                        DisclosureGroup(L10n.text("Event data", locale: locale)) { AlarmTextBlock(text: data, monospaced: true) }
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            Text(L10n.text("No history returned for the last 30 days.", locale: locale)).font(.callout).foregroundColor(.secondary)
        }
    }
}

enum AlarmDisplay {
    static func date(_ date: Date?, locale: Locale = Locale(identifier: "en")) -> String {
        guard let date else { return L10n.text("Unknown", locale: locale) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter.string(from: date)
    }

    static func boolean(_ value: Bool?, locale: Locale = Locale(identifier: "en")) -> String {
        L10n.text(value.map { $0 ? "Yes" : "No" } ?? "Unknown", locale: locale)
    }
}
