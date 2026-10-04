import SwiftUI

struct ELBLoadBalancerDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", listeners = "Listeners", targetGroups = "Target Groups"
        var id: Self { self }
    }

    let loadBalancer: ELBLoadBalancer
    @ObservedObject var vm: ELBViewModel
    let onOpen: (ELBResourceReference) -> Void
    @State private var selectedTab: Tab

    init(loadBalancer: ELBLoadBalancer, vm: ELBViewModel, onOpen: @escaping (ELBResourceReference) -> Void = { _ in }, tab: Tab = .overview) {
        self.loadBalancer = loadBalancer
        self.vm = vm
        self.onOpen = onOpen
        _selectedTab = State(initialValue: tab)
    }

    private var isCurrentSelection: Bool { vm.scope != nil && vm.selectedLoadBalancer?.arn == loadBalancer.arn }
    private var isLoading: Bool {
        guard isCurrentSelection else { return false }
        switch selectedTab {
        case .overview: return vm.isLoadBalancersLoading
        case .listeners: return vm.isListenersLoading || vm.isRulesLoading
        case .targetGroups: return vm.isTargetGroupsLoading
        }
    }
    private var associatedGroups: [ELBTargetGroup] {
        isCurrentSelection ? vm.targetGroups.filter { $0.loadBalancerARNs.contains(loadBalancer.arn) } : []
    }

    var body: some View {
        VStack(spacing: 0) {
            ELBDetailHeader(name: loadBalancer.name, subtitle: "\(ELBDisplay.kind(loadBalancer.kind)) · \(ELBDisplay.returned(loadBalancer.scheme))",
                            arn: loadBalancer.arn, isLoading: isLoading, isEnabled: isCurrentSelection,
                            onRefresh: refresh, onCancel: cancel)
            Divider()
            DetailTabPicker(tabs: Tab.allCases, selection: $selectedTab).padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTab {
                    case .overview: overview
                    case .listeners:
                        ELBListenersView(loadBalancer: loadBalancer, vm: vm, onOpen: onOpen)
                    case .targetGroups: targetGroups
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .onChange(of: loadBalancer.arn) { _ in selectedTab = .overview }
        .onChange(of: vm.scope) { _ in selectedTab = .overview }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            ELBScopeCaption(scope: vm.scope)
            if let error = vm.loadBalancersError { NoticeBanner(message: error) }
            DetailGrid(items: [("Type", ELBDisplay.kind(loadBalancer.kind)), ("Scheme", ELBDisplay.returned(loadBalancer.scheme)),
                               ("State", ELBDisplay.returned(loadBalancer.state)), ("DNS name", ELBDisplay.returned(loadBalancer.dnsName))])
            if !loadBalancer.fields.isEmpty {
                DetailSectionTitle(title: "Configuration")
                ELBFieldRows(fields: loadBalancer.fields)
            }
        }
    }

    private var targetGroups: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Target groups associated with this load balancer in the current profile and region. These are configured relationships, not observed traffic.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if isCurrentSelection, let error = vm.targetGroupsError { NoticeBanner(message: error) }
            if isCurrentSelection && vm.isTargetGroupsLoading && vm.targetGroups.isEmpty {
                ProgressView("Loading associated target groups…").controlSize(.small)
            } else if !associatedGroups.isEmpty {
                ForEach(associatedGroups) { group in
                    ELBLinkedResourceRow(arn: group.arn, name: group.name, service: .targetGroups, scope: vm.scope, onOpen: onOpen)
                        .padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            } else if vm.targetGroupsError == nil && !vm.isTargetGroupsLoading {
                Text("No associated target groups were returned.").font(.callout).foregroundColor(.secondary)
            }
        }
        .onAppear { if isCurrentSelection { vm.loadTargetGroupsIfNeeded() } }
    }

    private func refresh() {
        switch selectedTab {
        case .overview: vm.refreshLoadBalancers()
        case .listeners:
            vm.refreshListeners()
        case .targetGroups: vm.refreshTargetGroups()
        }
    }

    private func cancel() {
        switch selectedTab {
        case .overview: vm.cancelLoadBalancers()
        case .listeners: vm.cancelDetails()
        case .targetGroups: vm.cancelTargetGroups()
        }
    }
}
