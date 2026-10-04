import SwiftUI

struct EC2ListView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: EC2ViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(
                title: "EC2 Instances",
                isLoading: vm.isLoading,
                searchText: $vm.searchText,
                onRefresh: { vm.refresh() },
                onCancel: { vm.cancelLoading() }
            )
            HStack(spacing: 8) {
                Picker(L10n.text("State", locale: locale), selection: $vm.stateFilter) {
                    ForEach(vm.availableStates, id: \.self) { state in
                        Text(state == "All" ? L10n.text("All states", locale: locale) : state).tag(state)
                    }
                }
                Picker(L10n.text("Health status", locale: locale), selection: $vm.healthFilter) {
                    ForEach(EC2ViewModel.HealthFilter.allCases) { filter in
                        Text(L10n.text(filter.title, locale: locale)).tag(filter)
                    }
                }
            }
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            List(vm.filteredInstances, selection: $vm.selectedInstance) { instance in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(instance.name)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .help(instance.name)
                        Spacer()
                        healthIndicator(for: instance)
                        Text(instance.instanceType)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize()
                    }
                    HStack(spacing: 8) {
                        Circle()
                            .fill(instance.state == "running" ? Color.green : Color.gray)
                            .frame(width: 7, height: 7)
                        Text(instance.instanceId).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(instance.state).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                .tag(instance)
                .help("\(instance.instanceId) · \(instance.privateIP ?? L10n.text("No private IP", locale: locale))")
            }
            .listStyle(.inset)
            .overlay {
                if !vm.isLoading, let error = vm.error {
                    EmptyStateView(text: error, icon: "exclamationmark.triangle")
                } else if !vm.isLoading && vm.filteredInstances.isEmpty {
                    EmptyStateView(text: vm.instances.isEmpty ? "No EC2 instances in this region" : "No matching instances. Try another search or filter.", icon: "server.rack")
                }
            }
            ResourceListFooter(visible: vm.filteredInstances.count, total: vm.instances.count)
        }
    }

    @ViewBuilder
    private func healthIndicator(for instance: EC2InstanceModel) -> some View {
        let health = vm.instanceHealth[instance.instanceId]
        if health?.needsAttention == true {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .help(L10n.text(health?.summary ?? "Needs attention", locale: locale))
        } else if health?.summary == "Checks passed" {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .help(L10n.text("Status checks passed", locale: locale))
        } else {
            Image(systemName: "minus.circle")
                .foregroundColor(.secondary)
                .help(L10n.text(health?.summary ?? "Status checks unavailable", locale: locale))
        }
    }
}
