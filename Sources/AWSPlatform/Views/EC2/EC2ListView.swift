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
            List(vm.filteredInstances, selection: $vm.selectedInstance) { instance in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(instance.name)
                            .fontWeight(.medium)
                        Spacer()
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
                if vm.isLoading {
                    ProgressView()
                } else if let error = vm.error {
                    EmptyStateView(text: error)
                } else if vm.filteredInstances.isEmpty {
                    EmptyStateView(text: "No EC2 instances")
                }
            }
        }
    }
}
