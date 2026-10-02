import SwiftUI

struct S3ObjectListView: View {
    @ObservedObject var vm: S3ViewModel
    let bucketName: String

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(
                title: "Objects",
                isLoading: vm.isLoading,
                searchText: $vm.objectSearchText,
                onRefresh: { vm.navigateToPrefix(bucket: bucketName, prefix: vm.currentPrefix) },
                onCancel: { vm.cancelLoading() }
            )
            if !vm.currentPrefix.isEmpty {
                HStack {
                    Button("Root") {
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
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
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
