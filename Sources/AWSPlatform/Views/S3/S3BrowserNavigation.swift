import SwiftUI

struct S3BreadcrumbView: View {
    @Environment(\.locale) private var locale
    let bucket: String
    let prefix: String
    let onNavigate: (String) -> Void

    var body: some View {
        let path = S3Breadcrumb.path(for: prefix)
        HStack(spacing: WorkspaceLayout.controlSpacing) {
            segment(path[0]).fixedSize()
            if let current = path.last, !current.isRoot {
                separator
                if path.count > 2 {
                    ScrollView(.horizontal) {
                        HStack(spacing: WorkspaceLayout.controlSpacing) {
                            ForEach(path.dropFirst().dropLast()) { item in
                                if item.id != path[1].id { separator }
                                segment(item).fixedSize()
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    separator
                }
                segment(current).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(.caption)
        .padding(.horizontal, WorkspaceLayout.contextSpacing)
        .padding(.vertical, WorkspaceLayout.controlSpacing)
    }

    private var separator: some View {
        Image(systemName: "chevron.right").foregroundColor(.secondary).accessibilityHidden(true)
    }

    @ViewBuilder
    private func segment(_ item: S3Breadcrumb) -> some View {
        let location = "s3://" + bucket + "/" + item.prefix
        let label = L10n.format("Directory %@", location, locale: locale)
        if item.id == Data(prefix.utf8) {
            Text(title(item)).foregroundColor(.secondary)
                .help(location).accessibilityLabel(label)
        } else {
            Button(title(item)) { onNavigate(item.prefix) }
                .buttonStyle(.borderless)
                .help(location).accessibilityLabel(label)
        }
    }

    private func title(_ item: S3Breadcrumb) -> String {
        if item.isRoot { return L10n.text("Root", locale: locale) }
        return item.name.isEmpty ? "/" : item.name
    }
}

struct S3ObjectPaginationFooter: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: S3ViewModel
    let bucket: String

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.controlSpacing) {
            if let error = vm.objectPageError {
                Text(L10n.text(error, locale: locale))
                    .foregroundColor(.red).textSelection(.enabled).lineLimit(3)
                    .help(L10n.text(error, locale: locale))
            }
            HStack(spacing: WorkspaceLayout.controlSpacing) {
                Text(vm.filteredObjects.count == vm.objects.count
                     ? L10n.format("%@ loaded items", String(vm.objects.count), locale: locale)
                     : L10n.format("%@ of %@ loaded items", String(vm.filteredObjects.count), String(vm.objects.count), locale: locale))
                Spacer(minLength: 0)
                if vm.hasMoreObjects {
                    Button(L10n.text(vm.isLoadingMoreObjects ? "Loading…" : vm.objectPageError == nil ? "Load more" : "Retry", locale: locale)) {
                        vm.loadMoreObjects(bucket: bucket)
                    }
                    .disabled(vm.isLoading)
                }
            }
            Text(L10n.text(vm.hasMoreObjects
                           ? "More items available. Search filters loaded items only."
                           : vm.hasLoadedObjectPage ? "All items loaded. Search filters this directory only." : "Search filters loaded items only.", locale: locale))
                .foregroundColor(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, WorkspaceLayout.contextSpacing)
        .padding(.vertical, WorkspaceLayout.controlSpacing)
        .overlay(alignment: .top) { Divider() }
    }
}
