import SwiftUI

struct EC2ListView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: EC2ViewModel

    var body: some View {
        let filteredInstances = vm.filteredInstances
        VStack(spacing: 0) {
            ListToolbar(
                title: "EC2 Instances",
                isLoading: vm.isLoading,
                searchText: $vm.searchText,
                onRefresh: { vm.refresh() },
                onCancel: { vm.cancelLoading() }
            )
            quickFilters
            if vm.isStale {
                NoticeBanner(message: "Showing previously loaded EC2 instances; they may be out of date.")
                if let error = vm.error { NoticeBanner(message: error) }
            }
            Divider()

            List(filteredInstances, selection: $vm.selectedInstance) { instance in
                VStack(alignment: .leading, spacing: WorkspaceLayout.listRowSpacing) {
                    Text(instance.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .help(instance.name)
                    Text(instance.instanceId)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: WorkspaceLayout.controlSpacing) {
                        Text(instance.privateIP ?? L10n.text("No private IP", locale: locale))
                            .monospaced()
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Circle()
                            .fill(EC2DetailHeaderView.statusColor(for: instance.state))
                            .frame(width: 7, height: 7)
                        Text(instance.state).lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, WorkspaceLayout.listRowPadding)
                .tag(instance)
                .help("\(instance.instanceId) · \(instance.privateIP ?? L10n.text("No private IP", locale: locale))")
            }
            .listStyle(.inset)
            .overlay {
                if !vm.isLoading, !vm.isStale, let error = vm.error {
                    EmptyStateView(text: error, icon: "exclamationmark.triangle")
                } else if !vm.isLoading && filteredInstances.isEmpty {
                    EmptyStateView(text: vm.instances.isEmpty ? "No EC2 instances in this region" : "No matching instances. Try another search or filter.", icon: "server.rack")
                }
            }
            ResourceListFooter(visible: filteredInstances.count, total: vm.instances.count)
        }
    }

    private var quickFilters: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.quickFilterSpacing) {
            HStack(spacing: WorkspaceLayout.quickFilterSpacing) {
                filterButton("All", state: "All")
                filterButton("Running", state: "running")
                filterButton("Stopped", state: "stopped")
                if !vm.otherStates.isEmpty {
                    Menu {
                        ForEach(vm.otherStates, id: \.self) { state in
                            Button { vm.stateFilter = state } label: {
                                if vm.stateFilter == state {
                                    Label("\(state) (\(vm.loadedCount(for: state)))", systemImage: "checkmark")
                                } else {
                                    Text("\(state) (\(vm.loadedCount(for: state)))")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(vm.otherStates.contains(vm.stateFilter) ? .accentColor : .secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(L10n.text("Other states", locale: locale))
                    .accessibilityLabel(L10n.text("Other states", locale: locale))
                    .accessibilityValue(vm.otherStates.contains(vm.stateFilter) ? vm.stateFilter : "")
                    .accessibilityIdentifier("ec2-filter-other")
                }
            }
            if vm.otherStates.contains(vm.stateFilter) {
                Text(L10n.format("State: %@", vm.stateFilter, locale: locale))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
        .padding(.horizontal, WorkspaceLayout.listHorizontalPadding)
        .padding(.vertical, WorkspaceLayout.listVerticalPadding)
    }

    private func filterButton(_ title: String, state: String) -> some View {
        let selected = vm.stateFilter == state
        return Button { vm.stateFilter = state } label: {
            HStack(spacing: WorkspaceLayout.quickFilterSpacing) {
                Text(L10n.text(title, locale: locale)).lineLimit(1)
                Text(String(vm.loadedCount(for: state))).monospacedDigit()
            }
            .padding(.horizontal, WorkspaceLayout.controlSpacing)
            .padding(.vertical, WorkspaceLayout.quickFilterSpacing)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.accentColor.opacity(WorkspaceLayout.quickFilterSelectionOpacity) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("ec2-filter-\(state)")
    }
}
