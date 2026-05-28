import SwiftUI

struct S3ObjectListView: View {
    @ObservedObject var vm: S3ViewModel
    let bucketName: String

    var body: some View {
        VStack(spacing: 0) {
            if !vm.currentPrefix.isEmpty {
                HStack {
                    Button("Root") {
                        vm.navigateToPrefix(bucket: bucketName, prefix: "")
                    }
                    Text(vm.currentPrefix)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
            }

            List(vm.objects, selection: $vm.selectedObject) { object in
                HStack {
                    Image(systemName: object.isPrefix ? "folder" : "doc")
                        .foregroundColor(object.isPrefix ? .blue : .secondary)
                    Text(lastComponent(of: object.key))
                    Spacer()
                    if let size = object.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if object.isPrefix {
                        vm.navigateToPrefix(bucket: bucketName, prefix: object.key)
                    } else {
                        vm.selectedObject = object
                    }
                }
            }
        }
        .overlay {
            if vm.isLoading {
                ProgressView()
            } else if let error = vm.error {
                EmptyStateView(text: error)
            } else if vm.objects.isEmpty {
                EmptyStateView(text: "No objects at this prefix")
            }
        }
    }

    private func lastComponent(of key: String) -> String {
        let trimmed = key.hasSuffix("/") ? String(key.dropLast()) : key
        return trimmed.split(separator: "/").last.map(String.init) ?? key
    }
}
