import SwiftUI

struct ELBLoadBalancerListView: View {
    @ObservedObject var vm: ELBViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(title: "Load balancers", isLoading: vm.isLoadBalancersLoading, searchText: $vm.searchText,
                        onRefresh: vm.refreshLoadBalancers, onCancel: vm.cancelLoadBalancers,
                        searchPlaceholder: "Search load balancers")
                .disabled(vm.scope == nil)
            VStack(alignment: .leading, spacing: 8) {
                ELBScopeCaption(scope: vm.scope)
                Picker("Load balancer type", selection: $vm.kindFilter) {
                    Text("All types").tag("All")
                    ForEach(Set(vm.loadBalancers.map(\.kind)).sorted(), id: \.self) { kind in
                        Text(ELBDisplay.kind(kind)).tag(kind)
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
                    Text("\(ELBDisplay.kind(lb.kind)) · \(ELBDisplay.returned(lb.scheme))")
                        .font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                .padding(.vertical, 5).tag(lb).help(lb.arn)
            }
            .listStyle(.inset)
            .overlay {
                if vm.isLoadBalancersLoading && vm.loadBalancers.isEmpty {
                    ProgressView("Loading load balancers…")
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
