import SwiftUI

struct ELBLoadBalancerListView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: ELBViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(title: "Load balancers", isLoading: vm.isLoadBalancersLoading, searchText: $vm.searchText,
                        onRefresh: vm.refreshLoadBalancers, onCancel: vm.cancelLoadBalancers,
                        searchPlaceholder: "Search load balancers")
                .disabled(vm.scope == nil)
            VStack(alignment: .leading, spacing: 8) {
                ELBScopeCaption(scope: vm.scope)
                Picker(L10n.text("Load balancer type", locale: locale), selection: $vm.kindFilter) {
                    Text(L10n.text("All types", locale: locale)).tag("All")
                    ForEach(Set(vm.loadBalancers.map(\.kind)).sorted(), id: \.self) { kind in
                        Text(L10n.text(ELBDisplay.kind(kind), locale: locale)).tag(kind)
                    }
                }
                .labelsHidden().disabled(vm.scope == nil)
                if let error = vm.loadBalancersError { NoticeBanner(message: error) }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            List(vm.filteredLoadBalancers, selection: $vm.selectedLoadBalancer) { lb in
                VStack(alignment: .leading, spacing: 6) {
                    Text(lb.name).fontWeight(.medium).lineLimit(2).help(lb.name)
                    Text("\(L10n.text(ELBDisplay.kind(lb.kind), locale: locale)) · \(ELBDisplay.returned(lb.scheme, locale: locale))")
                        .font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                .padding(.vertical, 5).tag(lb).help(lb.arn)
            }
            .listStyle(.inset)
            .overlay {
                if vm.isLoadBalancersLoading && vm.loadBalancers.isEmpty {
                    ProgressView(L10n.text("Loading load balancers…", locale: locale))
                } else if !vm.isLoadBalancersLoading && vm.filteredLoadBalancers.isEmpty {
                    EmptyStateView(text: emptyMessage, icon: "point.3.connected.trianglepath.dotted")
                }
            }
            ResourceListFooter(visible: vm.filteredLoadBalancers.count, total: vm.loadBalancers.count)
        }
    }

    private var emptyMessage: String {
        if vm.scope == nil { return "Choose a profile to view load balancers." }
        if vm.loadBalancersError != nil { return "No load balancer list is available. Use Refresh to retry." }
        return vm.loadBalancers.isEmpty ? "No ALB, NLB or GWLB resources were returned in this region."
            : "No matching load balancers. Try another search or type."
    }
}
