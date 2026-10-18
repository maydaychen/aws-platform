import SwiftUI

struct CodeCommitBrowserView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: CodeCommitBrowserViewModel
    let section: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.text("Repository access may incur active-user, request or KMS charges. Queries run only when requested.", locale: locale))
                    .font(.caption).foregroundColor(.secondary)
                if section == "Source files" { source }
                else if section == "Commit differences" { CodeCommitDifferencesView(vm: vm) }
                else { CodeCommitPullRequestsView(vm: vm) }
                if !vm.loading.isEmpty { Button(L10n.text("Cancel", locale: locale), action: vm.cancel) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }

    private var source: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField(L10n.text("Commit SHA (40 characters)", locale: locale), text: $vm.commitSHA)
                .font(.body.monospaced())
            HStack {
                TextField(L10n.text("Repository folder path", locale: locale), text: $vm.folderPath)
                Button(L10n.text("Load folder", locale: locale), action: vm.loadFolder).disabled(vm.loading.contains(.folder))
                Button(L10n.text("Parent folder", locale: locale)) {
                    vm.folderPath = AWSCodeCommitBrowserService.parent(of: vm.folderPath); vm.loadFolder()
                }.disabled(vm.folderPath == "/" || vm.loading.contains(.folder))
            }
            if vm.loading.contains(.folder) || vm.loading.contains(.file) { ProgressView().controlSize(.small) }
            CodeCommitBrowserErrors(vm: vm, work: [.folder, .file])
            if let folder = vm.folder {
                Text(verbatim: folder.commitID).font(.caption.monospaced()).textSelection(.enabled)
                if folder.entries.isEmpty { Text(L10n.text("This repository folder is empty.", locale: locale)).foregroundColor(.secondary) }
                ForEach(folder.entries) { entry in
                    Button { vm.openEntry(entry) } label: {
                        HStack {
                            Image(systemName: entry.kind == .folder ? "folder" : "doc")
                            Text(verbatim: entry.path).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            if entry.kind == .submodule || entry.kind == .symbolicLink {
                                Text(L10n.text(entry.kind == .submodule ? "Submodule reference" : "Symbolic link", locale: locale))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }.disabled(entry.kind == .submodule)
                }
            }
            if let file = vm.file { CodeCommitFilePreviewView(file: file) }
        }
    }
}

struct CodeCommitBrowserErrors: View {
    @ObservedObject var vm: CodeCommitBrowserViewModel
    let work: [CodeCommitBrowserViewModel.Work]
    var body: some View {
        ForEach(work.indices, id: \.self) { index in
            if let error = vm.errors[work[index]] { NoticeBanner(message: error) }
        }
    }
}

struct CodeCommitFilePreviewView: View {
    @Environment(\.locale) private var locale
    let file: CodeCommitFilePreview
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: file.path).font(.headline).textSelection(.enabled)
            Text(verbatim: file.commitID).font(.caption.monospaced()).textSelection(.enabled)
            Text(L10n.format("%@ bytes", String(file.byteCount), locale: locale)).font(.caption).foregroundColor(.secondary)
            switch file.preview {
            case .text(let text):
                ScrollView(.horizontal) {
                    Text(verbatim: text).font(.body.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .binary: Text(L10n.text("Binary or non-UTF-8 content cannot be previewed.", locale: locale)).foregroundColor(.secondary)
            case .tooLarge: Text(L10n.text("Preview omitted: content exceeds 512 KiB or 5,000 lines.", locale: locale)).foregroundColor(.secondary)
            }
        }
    }
}
