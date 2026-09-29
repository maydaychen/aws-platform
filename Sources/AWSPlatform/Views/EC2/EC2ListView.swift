import SwiftUI

struct EC2ListView: View {
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
                Picker("State", selection: $vm.stateFilter) {
                    ForEach(vm.availableStates, id: \.self) { state in
                        Text(state == "All" ? "All states" : state).tag(state)
                    }
                }
                Picker("Health", selection: $vm.healthFilter) {
                    ForEach(EC2ViewModel.HealthFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
            }
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            List(vm.filteredInstances, selection: $vm.selectedInstance) { instance in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(instance.name)
                            .fontWeight(.medium)
                        Spacer()
                        healthIndicator(for: instance)
                        Text(instance.instanceType)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        Circle()
                            .fill(instance.state == "running" ? Color.green : Color.gray)
                            .frame(width: 7, height: 7)
                        Text(instance.instanceId)
                        if let privateIP = instance.privateIP {
                            Text(privateIP)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if !vm.isLoading, let error = vm.error {
                    EmptyStateView(text: error)
                } else if !vm.isLoading && vm.filteredInstances.isEmpty {
                    EmptyStateView(text: "No EC2 instances")
                }
            }
        }
    }

    @ViewBuilder
    private func healthIndicator(for instance: EC2InstanceModel) -> some View {
        let health = vm.instanceHealth[instance.instanceId]
        if health?.needsAttention == true {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .help(health?.summary ?? "Needs attention")
        } else if health?.summary == "Checks passed" {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .help("Status checks passed")
        } else {
            Image(systemName: "minus.circle")
                .foregroundColor(.secondary)
                .help(health?.summary ?? "Status checks unavailable")
        }
    }
}
