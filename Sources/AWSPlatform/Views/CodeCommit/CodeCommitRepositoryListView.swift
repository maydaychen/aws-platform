import SwiftUI

struct CodeCommitRepositoryListView: View {
    @ObservedObject var vm: CodeCommitViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(title: "CodeCommit repositories", isLoading: vm.isLoading,
                        searchText: $vm.searchText, onRefresh: vm.refresh,
                        onCancel: vm.cancelLoading, searchPlaceholder: "Search repositories")
            List(vm.filteredRepositories, selection: $vm.selectedRepository) { repository in
                VStack(alignment: .leading, spacing: 4) {
                    Text(repository.name).fontWeight(.medium).lineLimit(1).help(repository.name)
                    Text(repository.id).font(.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.vertical, 4)
                .tag(repository)
            }
            .listStyle(.inset)
            .overlay {
                if !vm.isLoading, vm.repositories.isEmpty, let error = vm.error {
                    EmptyStateView(text: error, icon: "exclamationmark.triangle")
                } else if !vm.isLoading, vm.filteredRepositories.isEmpty {
                    EmptyStateView(text: vm.repositories.isEmpty
                        ? "No CodeCommit repositories in this region"
                        : "No matching repositories. Try another search.",
                        icon: "chevron.left.forwardslash.chevron.right")
                }
            }
            if !vm.repositories.isEmpty, let error = vm.error { NoticeBanner(message: error) }
            ResourceListFooter(visible: vm.filteredRepositories.count, total: vm.repositories.count)
        }
    }
}
