import SwiftUI

struct EC2TargetGroupsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: EC2TargetGroupsViewModel
    let scope: MonitoringScope?
    let instanceID: String
    let onOpen: (ELBResourceReference) -> Void

    private var canLoad: Bool {
        scope?.isValid == true && vm.scope == scope && vm.instanceID == instanceID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls
                ELBScopeCaption(scope: scope)
                Text(L10n.text("Manual scan only. Lists target groups in this account and region, then requests target health for each instance-type group. Pagination and retries can add requests. IP and Lambda groups are excluded.", locale: locale))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if canLoad, let error = vm.error { NoticeBanner(message: error) }
                if canLoad && vm.isLoading {
                    ProgressView(L10n.text("Checking instance-type target groups…", locale: locale)).controlSize(.small)
                }
                if canLoad, let result = vm.result {
                    resultContent(result)
                } else if !vm.isLoading {
                    EmptyStateView(text: canLoad ? "Scan to find this instance's registered target groups and ports."
                                   : "Select an instance in a verified profile to scan its target groups.", icon: "target")
                        .frame(minHeight: 180)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .onAppear { configure() }
        .onChange(of: scope) { _ in configure() }
        .onChange(of: instanceID) { _ in configure() }
        .onDisappear { vm.reset() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Text(L10n.text("Target group membership", locale: locale)).font(.headline)
            Spacer(minLength: 0)
            if vm.isLoading {
                Button(L10n.text("Cancel", locale: locale), action: vm.cancel)
            }
            Button(L10n.text(vm.result == nil ? "Scan target groups" : "Scan again", locale: locale)) {
                if vm.result == nil { vm.load() }
                else { vm.refresh() }
            }
            .disabled(!canLoad || vm.isLoading)
        }
    }

    @ViewBuilder
    private func resultContent(_ result: ELBMembershipResult) -> some View {
        Text(L10n.format("Successfully checked %@ of %@ instance-type target groups", String(result.checkedGroupCount), String(result.totalGroupCount), locale: locale))
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        if !result.isComplete {
            NoticeBanner(message: "Scan incomplete. The matches below cover successfully checked groups only; additional registrations may exist.")
        }
        if !result.failures.isEmpty {
            DisclosureGroup(L10n.format("Failed groups (%@)", String(result.failures.count), locale: locale)) {
                ELBFieldRows(fields: result.failures, isVerbatimLabels: true, isMessageValues: true).padding(.top, 8)
            }
            .font(.callout)
        }
        if result.matches.isEmpty {
            Text(L10n.text(result.isComplete ? "No registrations were found for this instance."
                 : "No registrations were found among the successfully checked groups.", locale: locale))
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(result.matches) { membership in
                VStack(alignment: .leading, spacing: 12) {
                    ELBLinkedResourceRow(arn: membership.group.arn, name: membership.group.name, service: .targetGroups,
                                         scope: canLoad ? scope : nil, onOpen: onOpen)
                    ForEach(membership.targets) { target in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 10) {
                                Text(target.port.map { L10n.format("Registered port %@", String($0), locale: locale) }
                                     ?? L10n.text("Registered port not returned", locale: locale)).font(.callout)
                                Spacer(minLength: 0)
                                ELBHealthLabel(state: target.state)
                            }
                            if let reason = target.reason {
                                Text(reason).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let description = target.description {
                                Text(description).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func configure() { vm.configure(scope: scope, instanceID: instanceID) }
}
