import SwiftUI

struct SNSTopicListView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: SNSViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(title: "SNS Topics", isLoading: vm.isLoading, searchText: $vm.searchText,
                        onRefresh: vm.refresh, onCancel: vm.cancelLoading)
            Picker(L10n.text("Topic type", locale: locale), selection: $vm.kindFilter) {
                Text(L10n.text("All types", locale: locale)).tag(Optional<SNSTopicKind>.none)
                ForEach(SNSTopicKind.allCases) { kind in Text(L10n.text(kind.title, locale: locale)).tag(Optional(kind)) }
            }
            .labelsHidden().padding(.horizontal, 12).padding(.bottom, 10)
            if let error = vm.error {
                NoticeBanner(message: vm.topics.isEmpty ? error : "Showing the previous topic list. \(error)")
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider()
            List(vm.filteredTopics, selection: $vm.selectedTopic) { topic in
                VStack(alignment: .leading, spacing: 5) {
                    Text(topic.name).fontWeight(.medium).lineLimit(2).help(topic.name)
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right").foregroundColor(.secondary)
                        Text(L10n.text(topic.kind.title, locale: locale)).foregroundColor(.secondary)
                    }
                    .font(.caption)
                }
                .padding(.vertical, 5).tag(topic).help(topic.arn)
            }
            .listStyle(.inset)
            .overlay {
                if vm.isLoading && vm.topics.isEmpty {
                    ProgressView(L10n.text("Loading topics…", locale: locale))
                } else if !vm.isLoading && vm.filteredTopics.isEmpty {
                    EmptyStateView(text: emptyMessage, icon: "dot.radiowaves.left.and.right")
                }
            }
            ResourceListFooter(visible: vm.filteredTopics.count, total: vm.topics.count)
        }
    }

    private var emptyMessage: String {
        if vm.scope == nil { return "Choose a profile to view topics." }
        if vm.error != nil { return "No topic list is available. Use Refresh to retry." }
        return vm.topics.isEmpty ? "No SNS topics in this region."
            : "No matching topics. Try another search or filter."
    }
}
