import SwiftUI

struct S3VersionsView: View {
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: S3VersionsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.controlSpacing) {
            HStack {
                Text(L10n.text("Object versions", locale: locale)).font(.title2.weight(.semibold))
                Spacer()
                Button(L10n.text("Done", locale: locale)) { vm.reset(); dismiss() }
            }
            Text(vm.context.map { "s3://" + $0.bucket + "/" + (vm.key ?? "") } ?? "")
                .font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("Read only. Each loaded page uses S3 LIST requests, which can incur charges. Version storage is billed separately; versioning is not enabled by this view.", locale: locale))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text(vm.hasLoaded ? "Reload versions" : "Load versions", locale: locale), action: vm.load)
                    .disabled(vm.isLoading || vm.context == nil || vm.key == nil)
                if vm.isLoading {
                    ProgressView().controlSize(.small)
                    Button(L10n.text("Cancel", locale: locale), action: vm.cancelLoading)
                }
            }
            ResourceSearchField(text: $vm.searchText, placeholder: "Search loaded version IDs")
            if let error = vm.error { NoticeBanner(message: error) }
            List(vm.filteredVersions) { version in
                VStack(alignment: .leading, spacing: WorkspaceLayout.controlSpacing) {
                    HStack(alignment: .top) {
                        Label(L10n.text(version.kind == .deleteMarker ? "Delete marker" : "Object version", locale: locale),
                              systemImage: version.kind == .deleteMarker ? "minus.circle" : "doc")
                        Spacer()
                        Text(L10n.text(version.isLatest.map { $0 ? "Latest" : "Previous" } ?? "Latest status not returned", locale: locale))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Text(version.versionID).font(.caption.monospaced()).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    DetailFieldRows(items: [
                        ("Last modified", version.lastModified.map(MonitoringDisplay.dateTime) ?? missing),
                        ("Size", version.size.map { $0.formatted(.byteCount(style: .file).locale(locale)) } ?? missing),
                        ("ETag", version.eTag ?? missing), ("Storage class", version.storageClass ?? missing)
                    ])
                }.padding(.vertical, WorkspaceLayout.controlSpacing)
            }
            .listStyle(.inset)
            .overlay {
                if !vm.isLoading, vm.filteredVersions.isEmpty {
                    EmptyStateView(text: !vm.hasLoaded ? "Load the selected object's versions manually." :
                        vm.hasMore ? "No matching versions in the pages loaded so far. More pages remain." :
                        vm.versions.isEmpty ? "No versions or delete markers returned for this key." : "No matching loaded versions.",
                        icon: "clock.arrow.circlepath")
                }
            }
            Text(L10n.text("Only this exact key is shown. Search covers loaded versions only.", locale: locale))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if vm.hasMore {
                Text(L10n.text("Partial version list · More pages available", locale: locale)).font(.caption).foregroundColor(.secondary)
                Button(L10n.text("Load more", locale: locale), action: vm.loadMore).disabled(vm.isLoading)
            }
        }
        .padding(WorkspaceLayout.contextSpacing)
        .frame(minWidth: 480, idealWidth: 640, minHeight: 480, idealHeight: 680)
        .onDisappear { vm.reset() }
    }

    private var missing: String { L10n.text("Not returned", locale: locale) }
}
