import SwiftUI

struct CodeCommitCommitView: View {
    @Environment(\.locale) private var locale
    let commit: CodeCommitCommit?
    let isLoading: Bool
    let error: String?
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                DetailSectionTitle(title: "Latest branch commit")
                Spacer(minLength: 0)
                Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                    .disabled(isLoading)
                    .help(L10n.text("Refresh branch head", locale: locale))
                    .accessibilityLabel(L10n.text("Refresh branch head", locale: locale))
            }
            if isLoading {
                ProgressView(L10n.text("Loading branch commit…", locale: locale)).controlSize(.small)
            }
            if let error { NoticeBanner(message: error) }
            if let commit {
                DetailFieldRows(items: [
                    ("Commit ID", commit.id),
                    ("Author", person(commit.authorName, commit.authorEmail)),
                    ("Author time (Git)", value(commit.authorDate)),
                    ("Committer", person(commit.committerName, commit.committerEmail)),
                    ("Committer time (Git)", value(commit.committerDate)),
                    ("Parent commits", commit.parentIDs.isEmpty ? L10n.text("None", locale: locale) : commit.parentIDs.joined(separator: "\n"))
                ])
                DetailSectionTitle(title: "Commit message")
                Text(commit.message.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("No commit message", locale: locale))
                    .font(.body).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("This is the branch head returned by the last query. Refresh to check for updates.", locale: locale))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func person(_ name: String?, _ email: String?) -> String {
        let parts = [name, email].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? L10n.text("Not returned", locale: locale) : parts.joined(separator: " · ")
    }

    private func value(_ value: String?) -> String {
        value.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("Not returned", locale: locale)
    }
}
