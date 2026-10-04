import SwiftUI

struct ELBTargetGroupDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", targets = "Targets"
        var id: Self { self }
    }

    let group: ELBTargetGroup
    @ObservedObject var vm: ELBViewModel
    let onOpen: (ELBResourceReference) -> Void
    @State private var selectedTab: Tab

    init(group: ELBTargetGroup, vm: ELBViewModel, onOpen: @escaping (ELBResourceReference) -> Void = { _ in }, tab: Tab = .overview) {
        self.group = group
        self.vm = vm
        self.onOpen = onOpen
        _selectedTab = State(initialValue: tab)
    }

    private var isCurrentSelection: Bool { vm.scope != nil && vm.selectedTargetGroup?.arn == group.arn }
    private var isLoading: Bool {
        isCurrentSelection && (selectedTab == .overview ? vm.isTargetGroupsLoading : vm.isTargetsLoading)
    }

    var body: some View {
        VStack(spacing: 0) {
            ELBDetailHeader(name: group.name, subtitle: "Target group · \(group.targetType)", arn: group.arn,
                            isLoading: isLoading, isEnabled: isCurrentSelection,
                            onRefresh: refresh, onCancel: cancel)
            Divider()
            DetailTabPicker(tabs: Tab.allCases, selection: $selectedTab).padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .overview: overview
                    case .targets: targets
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .onChange(of: group.arn) { _ in selectedTab = .overview }
        .onChange(of: vm.scope) { _ in selectedTab = .overview }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            ELBScopeCaption(scope: vm.scope)
            if let error = vm.targetGroupsError { NoticeBanner(message: error) }
            DetailGrid(items: [("Target type", group.targetType), ("Protocol", ELBDisplay.returned(group.protocolName)),
                               ("Default port", group.port.map(String.init) ?? (group.targetType == "lambda" ? "Not applicable" : "Not returned"))])
            if !group.fields.isEmpty {
                DetailSectionTitle(title: "Configuration and health checks")
                ELBFieldRows(fields: group.fields)
            }
            DetailSectionTitle(title: "Associated load balancers")
            if group.loadBalancerARNs.isEmpty {
                Text("No associated load balancers were returned.").font(.callout).foregroundColor(.secondary)
            } else {
                ForEach(group.loadBalancerARNs, id: \.self) { arn in
                    ELBLinkedResourceRow(arn: arn, name: ELBDisplay.resourceName(arn), service: .loadBalancers,
                                         scope: isCurrentSelection ? vm.scope : nil, onOpen: onOpen)
                        .padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private var targets: some View {
        if isCurrentSelection && vm.isTargetsLoading {
            ProgressView("Loading target health…").controlSize(.small)
        } else if isCurrentSelection, let error = vm.targetsError {
            NoticeBanner(message: error)
            Button("Retry target health", action: vm.refreshTargets)
        } else if isCurrentSelection && !vm.targets.isEmpty {
            Text("\(vm.targets.count) target health \(vm.targets.count == 1 ? "entry" : "entries") · Port identifies each registration")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(vm.targets) { target in
                    ELBTargetHealthRow(target: target, group: group, scope: vm.scope, onOpen: onOpen)
                }
            }
        } else {
            EmptyStateView(text: "No target health entries were returned.", icon: "target").frame(minHeight: 180)
        }
    }

    private func refresh() {
        if selectedTab == .overview { vm.refreshTargetGroups() }
        else { vm.refreshTargets() }
    }

    private func cancel() {
        if selectedTab == .overview { vm.cancelTargetGroups() }
        else { vm.cancelDetails() }
    }
}

struct ELBTargetHealthRow: View {
    let target: ELBTargetHealth
    let group: ELBTargetGroup
    let scope: MonitoringScope?
    let onOpen: (ELBResourceReference) -> Void

    var body: some View {
        DisclosureGroup {
            ELBTargetHealthDetails(target: target, group: group, scope: scope, onOpen: onOpen).padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(target.targetID).font(.callout.weight(.medium)).lineLimit(2).help(target.targetID)
                HStack(spacing: 10) {
                    ELBHealthLabel(state: target.state)
                    Text(target.port.map { "Port \(String($0))" } ?? (group.targetType == "lambda" ? "Lambda target" : "Port not returned"))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ELBTargetHealthDetails: View {
    let target: ELBTargetHealth
    let group: ELBTargetGroup
    let scope: MonitoringScope?
    let onOpen: (ELBResourceReference) -> Void

    private var reference: ELBResourceReference? {
        guard let scope else { return nil }
        return ELBResourceReference.target(target, group: group, scope: scope)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.targetID).font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            DetailGrid(items: [("Health state", ELBDisplay.returned(target.state)),
                               ("Registered port", target.port.map(String.init) ?? (group.targetType == "lambda" ? "Not applicable" : "Not returned")),
                               ("Availability zone", ELBDisplay.returned(target.availabilityZone)),
                               ("Reason", ELBDisplay.returned(target.reason))])
            if let description = target.description, !description.isEmpty {
                Text(description).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !target.fields.isEmpty { ELBFieldRows(fields: target.fields) }
            if let reference {
                if reference.service == .lambda, let qualifier = reference.qualifier {
                    Text("Registered qualifier: \(qualifier). Open shows function-level details, not this specific alias or version.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button(openTitle(reference.service)) { onOpen(reference) }
            } else if group.targetType == "ip" {
                Text("IP target. No instance association is inferred.").font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openTitle(_ service: AWSService) -> String {
        switch service {
        case .ec2: return "Open EC2 instance"
        case .lambda: return "Open Lambda function"
        case .loadBalancers: return "Open load balancer"
        default: return "Open"
        }
    }
}
