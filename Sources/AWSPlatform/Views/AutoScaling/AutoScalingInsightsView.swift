import SwiftUI

struct AutoScalingInsightsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: AutoScalingInsightsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DetailSectionTitle(title: "Launch template versions")
            Text(L10n.text("Only template references returned by this group are queried. Version aliases retain their meaning; SSM AMI aliases and user data are not resolved or displayed.", locale: locale))
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Button(L10n.text("Load template versions", locale: locale), action: vm.loadTemplateVersions)
                    .disabled(vm.scope == nil || vm.group == nil || vm.isTemplatesLoading)
                    .accessibilityIdentifier("asg.insights.load-template-versions")
                if vm.isTemplatesLoading { ProgressView().controlSize(.small) }
            }
            if let error = vm.templatesError { Text(L10n.text(error, locale: locale)).foregroundColor(.red) }
            if vm.templates.isEmpty {
                Text(L10n.text("No launch template references returned by this group.", locale: locale)).foregroundColor(.secondary)
            } else if vm.didLoadTemplates && !vm.isTemplatesLoading && vm.templatesError == nil && vm.templateVersions.isEmpty {
                Text(L10n.text("No launch template versions returned.", locale: locale)).foregroundColor(.secondary)
            }
            ForEach(Array(vm.templateVersions.enumerated()), id: \.offset) { _, item in template(item) }
            Divider()
            DetailSectionTitle(title: "Instance refresh history")
            Text(L10n.text("Read-only history for this group from the last six weeks. Entries with an unknown start time remain visible. No automatic polling.", locale: locale))
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Button(L10n.text("Load instance refreshes", locale: locale), action: vm.loadInstanceRefreshes)
                    .disabled(vm.scope == nil || vm.group == nil || vm.isRefreshesLoading)
                    .accessibilityIdentifier("asg.insights.load-instance-refreshes")
                if vm.isRefreshesLoading { ProgressView().controlSize(.small) }
            }
            if let error = vm.refreshesError { Text(L10n.text(error, locale: locale)).foregroundColor(.red) }
            if vm.didLoadRefreshes && !vm.isRefreshesLoading && vm.refreshesError == nil && vm.instanceRefreshes.isEmpty {
                Text(L10n.text("No instance refreshes returned for this time window.", locale: locale)).foregroundColor(.secondary)
            }
            ForEach(vm.instanceRefreshes) { item in
                DetailFieldRows(items: [("Instance refresh ID", item.id), ("Status", value(item.status)),
                    ("Progress (%)", item.percentageComplete.map { String($0) } ?? missing),
                    ("Instances remaining", item.instancesRemaining.map { String($0) } ?? missing),
                    ("Started", date(item.startedAt)), ("Ended", date(item.endedAt)),
                    ("Status reason", value(item.statusReason)), ("Refresh strategy", value(item.strategy))])
            }
            if vm.isTemplatesLoading || vm.isRefreshesLoading {
                Button(L10n.text("Cancel loading", locale: locale), action: vm.cancelLoading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func template(_ item: ASGTemplateVersion) -> some View {
        DetailFieldRows(items: [("Launch template ID", item.templateID), ("Launch template name", value(item.templateName)),
            ("Requested template version", value(item.reference.version)), ("Resolved template version", String(item.version)),
            ("Default version", boolean(item.isDefault)), ("Description", value(item.description)),
            ("Created", date(item.createdAt)), ("Created by", value(item.createdBy)),
            ("AMI ID or SSM parameter", value(item.imageID)), ("Instance type", value(item.instanceType)),
            ("Key pair", value(item.keyName)), ("Security groups", item.securityGroupIDs.map { $0.isEmpty ? L10n.text("None", locale: locale) : $0.joined(separator: "\n") } ?? missing),
            ("Instance profile ARN", value(item.instanceProfileARN)), ("Instance profile name", value(item.instanceProfileName)),
            ("EBS optimized", boolean(item.ebsOptimized)), ("Detailed monitoring", boolean(item.detailedMonitoring))])
    }

    private var missing: String { L10n.text("Not returned", locale: locale) }
    private func value(_ value: String?) -> String { value ?? missing }
    private func date(_ value: Date?) -> String { value.map { $0.formatted(.dateTime.year().month().day().hour().minute().locale(locale)) } ?? missing }
    private func boolean(_ value: Bool?) -> String { value.map { L10n.text($0 ? "Yes" : "No", locale: locale) } ?? L10n.text("Unknown", locale: locale) }
}
