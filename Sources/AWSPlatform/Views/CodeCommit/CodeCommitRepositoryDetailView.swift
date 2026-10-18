import SwiftUI

struct CodeCommitRepositoryDetailView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: CodeCommitViewModel
    var browserVM: CodeCommitBrowserViewModel? = nil
    @State private var section = "Overview"

    var body: some View {
        VStack(spacing: 0) {
            if let repository = vm.selectedRepository {
                VStack(spacing: 0) {
                    header(repository)
                    if browserVM != nil {
                        Picker(L10n.text("Repository section", locale: locale), selection: $section) {
                            ForEach(["Overview", "Source files", "Commit differences", "Pull requests"], id: \.self) {
                                Text(L10n.text($0, locale: locale)).tag($0)
                            }
                        }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 8)
                    }
                    Divider()
                    if section != "Overview", let browserVM {
                        CodeCommitBrowserView(vm: browserVM, section: section)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                metadata
                                branches
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                        }
                        .id(repository.id)
                    }
                }
            } else {
                EmptyStateView(text: "Select a CodeCommit repository", icon: "chevron.left.forwardslash.chevron.right")
            }
        }
        .onAppear(perform: configureBrowser)
        .onChange(of: vm.scope) { _ in configureBrowser() }
        .onChange(of: vm.selectedRepository) { _ in section = "Overview"; configureBrowser() }
        .onChange(of: vm.commit) { _ in configureBrowser() }
        .onDisappear { browserVM?.reset() }
    }

    private func configureBrowser() {
        browserVM?.configure(scope: vm.scope, repository: vm.selectedRepository, commit: vm.commit)
    }

    private func header(_ repository: CodeCommitRepository) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(repository.name).font(.title2.weight(.semibold))
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: vm.refreshRepository) { Image(systemName: "arrow.clockwise") }
                    .disabled(vm.isLoading || vm.isRepositoryLoading || vm.isBranchesLoading)
                    .help(L10n.text("Refresh repository details and branches", locale: locale))
                    .accessibilityLabel(L10n.text("Refresh repository details and branches", locale: locale))
                if vm.isRepositoryLoading || vm.isBranchesLoading || vm.isCommitLoading {
                    Button(L10n.text("Cancel", locale: locale), action: vm.cancelLoading)
                }
            }
            Text(repository.id).font(.caption.monospaced()).foregroundColor(.secondary)
                .textSelection(.enabled)
            Text(L10n.text("Repository metadata and branch heads · Read only", locale: locale))
                .font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    @ViewBuilder
    private var metadata: some View {
        DetailSectionTitle(title: "Repository")
        if vm.isRepositoryLoading {
            ProgressView(L10n.text("Loading repository details…", locale: locale)).controlSize(.small)
        }
        if let error = vm.repositoryError { NoticeBanner(message: error) }
        if let detail = vm.repositoryDetail {
            DetailFieldRows(items: [
                ("Repository ID", detail.id), ("ARN", detail.arn), ("Account ID", detail.accountID),
                ("Description", value(detail.description)), ("Default branch", value(detail.defaultBranch)),
                ("HTTPS clone URL", value(detail.cloneURLHTTP)), ("SSH clone URL", value(detail.cloneURLSSH)),
                ("Created", date(detail.creationDate)), ("Last Modified", date(detail.lastModifiedDate))
            ])
        }
    }

    @ViewBuilder
    private var branches: some View {
        DetailSectionTitle(title: "Branches")
        if vm.isBranchesLoading {
            ProgressView(L10n.text("Loading branches…", locale: locale)).controlSize(.small)
        }
        if let error = vm.branchesError { NoticeBanner(message: error) }
        if !vm.branches.isEmpty {
            Picker(L10n.text("Branch", locale: locale), selection: $vm.selectedBranch) {
                Text(L10n.text("Select a branch", locale: locale)).tag(String?.none)
                ForEach(vm.branches, id: \.self) { branch in
                    Text(branch).lineLimit(1).help(branch).tag(Optional(branch))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            if vm.selectedBranch != nil {
                CodeCommitCommitView(commit: vm.commit, isLoading: vm.isCommitLoading,
                                     error: vm.commitError, onRefresh: vm.refreshCommit)
            }
        } else if !vm.isBranchesLoading, vm.branchesError == nil {
            Text(L10n.text("This repository has no branches yet.", locale: locale))
                .foregroundColor(.secondary)
        }
    }

    private func value(_ value: String?) -> String {
        value.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.text("Not returned", locale: locale)
    }

    private func date(_ date: Date?) -> String {
        date.map { $0.formatted(.dateTime.year().month().day().hour().minute().locale(locale)) }
            ?? L10n.text("Not returned", locale: locale)
    }
}
