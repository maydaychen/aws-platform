import SwiftUI

struct CodeCommitDifferencesView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: CodeCommitBrowserViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField(L10n.text("After commit SHA (40 characters)", locale: locale), text: $vm.commitSHA).font(.body.monospaced())
            TextField(L10n.text("Before commit SHA (optional for initial commit)", locale: locale), text: $vm.beforeSHA).font(.body.monospaced())
            Text(L10n.text("Compare fixed commits. An empty before SHA shows all files at the after commit.", locale: locale))
                .font(.caption).foregroundColor(.secondary)
            Button(L10n.text("Load changed files", locale: locale), action: vm.loadDifferences).disabled(vm.loading.contains(.differences))
            if vm.loading.contains(.differences) || vm.loading.contains(.changeFile) { ProgressView().controlSize(.small) }
            CodeCommitBrowserErrors(vm: vm, work: [.differences, .changeFile])
            if vm.completed.contains(.differences), vm.differences.isEmpty {
                Text(L10n.text("No changed files between these commits.", locale: locale)).foregroundColor(.secondary)
            }
            ForEach(vm.differences) { change in
                Button { vm.selectChange(change) } label: {
                    HStack {
                        Text(verbatim: change.type).font(.caption.monospaced())
                        Text(verbatim: change.path).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        if vm.selectedChange == change { Image(systemName: "checkmark") }
                    }
                }
            }
            if let change = vm.selectedChange {
                HStack {
                    Button(L10n.text("View before content", locale: locale)) { vm.loadChangeFile(before: true) }
                        .disabled(change.before == nil || change.before?.mode == "160000" || vm.beforeSHA.isEmpty)
                    Button(L10n.text("View after content", locale: locale)) { vm.loadChangeFile(before: false) }
                        .disabled(change.after == nil || change.after?.mode == "160000")
                }
                Text(L10n.text("Read-only before/after previews; repository content is never executed.", locale: locale))
                    .font(.caption).foregroundColor(.secondary)
            }
            if let file = vm.changeFile { CodeCommitFilePreviewView(file: file) }
        }
    }
}
