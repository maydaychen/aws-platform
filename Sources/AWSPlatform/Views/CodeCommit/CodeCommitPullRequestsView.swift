import SwiftUI

struct CodeCommitPullRequestsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: CodeCommitBrowserViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker(L10n.text("Pull request status", locale: locale), selection: $vm.pullRequestStatus) {
                    Text(L10n.text("Open pull requests", locale: locale)).tag("OPEN")
                    Text(L10n.text("Closed", locale: locale)).tag("CLOSED")
                    Text(L10n.text("All", locale: locale)).tag("")
                }.pickerStyle(.menu)
                Button(L10n.text("Load pull requests", locale: locale), action: vm.loadPullRequests)
                    .disabled(vm.loading.contains(.pullRequests))
            }
            if vm.loading.contains(.pullRequests) || vm.loading.contains(.pullRequest) { ProgressView().controlSize(.small) }
            CodeCommitBrowserErrors(vm: vm, work: [.pullRequests, .pullRequest])
            if vm.completed.contains(.pullRequests), vm.pullRequestIDs.isEmpty {
                Text(L10n.text("No pull requests match this status.", locale: locale)).foregroundColor(.secondary)
            }
            ForEach(vm.pullRequestIDs, id: \.self) { id in
                Button { vm.loadPullRequest(id) } label: {
                    HStack {
                        Text(verbatim: "#\(id)").frame(maxWidth: .infinity, alignment: .leading)
                        if vm.pullRequest?.id == id { Image(systemName: "checkmark") }
                    }
                }
            }
            if let request = vm.pullRequest {
                DetailFieldRows(items: [
                    ("Pull request ID", request.id), ("Title", value(request.title)),
                    ("Status", value(request.status)), ("Author ARN", value(request.authorARN)),
                    ("Source reference", value(request.sourceReference)), ("Destination reference", value(request.destinationReference)),
                    ("Source commit", value(request.sourceCommit)), ("Destination commit", value(request.destinationCommit)),
                    ("Created", date(request.createdAt)), ("Last Modified", date(request.updatedAt))
                ])
                Text(verbatim: value(request.description)).textSelection(.enabled)
            }
        }
    }
    private func value(_ value: String?) -> String { value ?? L10n.text("Not returned", locale: locale) }
    private func date(_ value: Date?) -> String {
        value?.formatted(.dateTime.year().month().day().hour().minute().locale(locale)) ?? L10n.text("Not returned", locale: locale)
    }
}
