import SwiftUI

struct S3ObjectListView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: S3ViewModel
    @ObservedObject var transferVM: S3TransferViewModel
    let bucketName: String
    let transferContext: S3TransferContext?

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(
                title: "Objects",
                isLoading: vm.isLoading,
                searchText: $vm.objectSearchText,
                onRefresh: { vm.navigateToPrefix(bucket: bucketName, prefix: vm.currentPrefix) },
                onCancel: { vm.cancelLoading() }
            )
            HStack {
                Button {
                    guard let context = transferContext else { return }
                    transferVM.chooseUpload(context: context) { await S3FilePanels.openFile(locale: locale) }
                } label: {
                    Label(L10n.text("Upload File", locale: locale), systemImage: "arrow.up.doc")
                }
                .disabled(!transferVM.canStart || transferContext == nil)
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 8)
            S3TransferStatusView(vm: transferVM)
            if !vm.currentPrefix.isEmpty {
                HStack {
                    Button(L10n.text("Root", locale: locale)) {
                        vm.navigateToPrefix(bucket: bucketName, prefix: "")
                    }
                    Text(vm.currentPrefix)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(vm.currentPrefix)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            Divider()

            List(vm.filteredObjects, selection: $vm.selectedObject) { object in
                HStack {
                    Image(systemName: object.isPrefix ? "folder" : "doc")
                        .foregroundColor(object.isPrefix ? .blue : .secondary)
                    Text(lastComponent(of: object.key))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(object.key)
                    Spacer()
                    if let size = object.size {
                        Text(size.formatted(.byteCount(style: .file).locale(locale)))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize()
                    }
                }
                .padding(.vertical, 4)
                .tag(object)
                .contentShape(Rectangle())
                .onTapGesture {
                    if object.isPrefix {
                        vm.navigateToPrefix(bucket: bucketName, prefix: object.key)
                    } else {
                        vm.selectedObject = object
                    }
                }
                .contextMenu {
                    if !object.isPrefix {
                        Button(L10n.text("Download", locale: locale)) {
                            guard let context = transferContext else { return }
                            transferVM.chooseDownload(context: context, object: object) {
                                await S3FilePanels.saveFile(key: object.key, locale: locale)
                            }
                        }.disabled(!transferVM.canStart || transferContext == nil)
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if !vm.isLoading, let error = vm.error {
                    EmptyStateView(text: error, icon: "exclamationmark.triangle")
                } else if !vm.isLoading && vm.filteredObjects.isEmpty {
                    EmptyStateView(text: vm.objects.isEmpty ? "No objects at this prefix" : "No matching objects", icon: "folder")
                }
            }
            ResourceListFooter(visible: vm.filteredObjects.count, total: vm.objects.count)
        }
    }

    private func lastComponent(of key: String) -> String {
        let trimmed = key.hasSuffix("/") ? String(key.dropLast()) : key
        return trimmed.split(separator: "/").last.map(String.init) ?? key
    }
}
