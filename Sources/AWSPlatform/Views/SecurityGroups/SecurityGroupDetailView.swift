import AppKit
import SwiftUI

struct SecurityGroupDetailView: View {
    @Environment(\.locale) private var locale
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", inbound = "Inbound rules", outbound = "Outbound rules", tags = "Tags"
        var id: Self { self }
    }

    let group: SecurityGroupModel
    @ObservedObject var vm: SecurityGroupsViewModel
    @State private var selectedTab: Tab
    @State private var ruleSearchText = ""

    init(group: SecurityGroupModel, vm: SecurityGroupsViewModel, tab: Tab = .overview) {
        self.group = group
        self.vm = vm
        _selectedTab = State(initialValue: tab)
    }

    private var currentGroup: SecurityGroupModel? {
        guard vm.scope?.isValid == true, let selected = vm.selectedGroup,
              selected.id == group.id, vm.groups.contains(selected) else { return nil }
        return selected
    }

    var body: some View {
        Group {
            if let group = currentGroup {
                VStack(spacing: 0) {
                    header(group)
                    Divider()
                    DetailTabPicker(tabs: Tab.allCases, selection: $selectedTab).padding(12)
                    if selectedTab == .inbound || selectedTab == .outbound {
                        ResourceSearchField(text: $ruleSearchText, placeholder: "Search protocols, ports or targets")
                            .padding(.horizontal, 16).padding(.bottom, 12)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            switch selectedTab {
                            case .overview: overview(group)
                            case .inbound: ruleList(group.inboundRules, inbound: true)
                            case .outbound: ruleList(group.outboundRules, inbound: false)
                            case .tags:
                                if group.tags.isEmpty {
                                    Text(L10n.text("No tags returned.", locale: locale)).font(.callout).foregroundColor(.secondary)
                                } else {
                                    SecurityGroupFieldRows(fields: group.tags, isVerbatimLabels: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 16)
                    }
                }
            } else {
                EmptyStateView(text: "Select a security group from the current profile and region.", icon: "shield")
            }
        }
        .onChange(of: group.id) { _ in resetLocalState() }
        .onChange(of: vm.scope) { _ in resetLocalState() }
    }

    private func header(_ group: SecurityGroupModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(group.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if vm.isLoading {
                    Button(action: vm.cancel) { Image(systemName: "xmark.circle") }
                        .help(L10n.text("Cancel security group refresh", locale: locale)).accessibilityLabel(L10n.text("Cancel security group refresh", locale: locale))
                }
                Button(action: vm.refresh) { Image(systemName: "arrow.clockwise") }
                    .disabled(vm.isLoading)
                    .help(L10n.text("Refresh security groups and rules", locale: locale)).accessibilityLabel(L10n.text("Refresh security groups and rules", locale: locale))
            }
            HStack(spacing: 6) {
                Text(group.id).font(.caption.monospaced()).foregroundColor(.secondary).textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(group.id, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help(L10n.text("Copy security group ID", locale: locale)).accessibilityLabel(L10n.text("Copy security group ID", locale: locale))
            }
            if vm.isStale {
                Text(L10n.text("Showing previously loaded security group configuration.", locale: locale))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func overview(_ group: SecurityGroupModel) -> some View {
        DetailGrid(items: [
            ("Group ID", group.id), ("Name", group.name),
            ("Owner account", group.ownerID ?? L10n.text("Not returned", locale: locale)), ("VPC", group.vpcID ?? L10n.text("Not returned", locale: locale)),
            ("Region", vm.scope?.region ?? L10n.text("Not returned", locale: locale)),
            ("Inbound rules", String(group.inboundRules.count)), ("Outbound rules", String(group.outboundRules.count))
        ])
        if let description = group.description, !description.isEmpty {
            DetailSectionTitle(title: "Description")
            Text(verbatim: description).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let owner = group.ownerID, owner != vm.scope?.accountID {
            NoticeBanner(message: "This visible security group is owned by another account. Its owner is shown above.")
        }
    }

    @ViewBuilder
    private func ruleList(_ rules: [SecurityGroupRule], inbound: Bool) -> some View {
        let rows = filteredRules(rules)
        Text(rows.count == rules.count
             ? L10n.format(rules.count == 1 ? "%@ rule" : "%@ rules", String(rules.count), locale: locale)
             : L10n.format("%@ of %@ rules", String(rows.count), String(rules.count), locale: locale))
            .font(.caption).foregroundColor(.secondary)
        if rows.isEmpty {
            EmptyStateView(text: rules.isEmpty ? (inbound ? "No inbound rules returned." : "No outbound rules returned.")
                           : "No matching rules. Try another search.", icon: "line.3.horizontal.decrease.circle")
                .frame(minHeight: 180)
        } else {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(rows.indices, id: \.self) { index in
                    SecurityGroupRuleRow(rule: rows[index], inbound: inbound)
                }
            }
        }
    }

    private func filteredRules(_ rules: [SecurityGroupRule]) -> [SecurityGroupRule] {
        let query = ruleSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rules }
        return rules.filter { rule in
            let values = [rule.protocolName, rule.portRange, rule.target]
                + [rule.description, rule.referencedGroupID, rule.referencedAccountID].compactMap { $0 }
                + rule.fields.flatMap { [$0.name, $0.value] }
            return values.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func resetLocalState() {
        selectedTab = .overview
        ruleSearchText = ""
    }
}
