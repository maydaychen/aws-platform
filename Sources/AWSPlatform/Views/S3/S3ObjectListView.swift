import SwiftUI
import UniformTypeIdentifiers

struct S3ObjectListView: View {
    @Environment(\.locale) private var locale
    @State private var isDropTargeted = false
    @State private var showsVersions = false
    @ObservedObject var vm: S3ViewModel
    @ObservedObject var transferVM: S3TransferViewModel
    let bucketName: String
    let transferContext: S3TransferContext?
    var versionsVM: S3VersionsViewModel? = nil
    private let transferPrefixIdentity: Data?

    init(vm: S3ViewModel, transferVM: S3TransferViewModel, bucketName: String,
         transferContext: S3TransferContext?, versionsVM: S3VersionsViewModel? = nil) {
        _vm = ObservedObject(wrappedValue: vm)
        _transferVM = ObservedObject(wrappedValue: transferVM)
        self.bucketName = bucketName
        self.transferContext = transferContext
        self.versionsVM = versionsVM
        // Store the literal identity so SwiftUI can detect an otherwise String-equivalent input change.
        transferPrefixIdentity = transferContext.map { Data($0.prefix.utf8) }
    }

    var body: some View {
        let filteredObjects = vm.filteredObjects
        VStack(spacing: 0) {
            ListToolbar(
                title: "Objects",
                isLoading: vm.isLoading,
                searchText: $vm.objectSearchText,
                onRefresh: { vm.navigateToPrefix(bucket: bucketName, prefix: vm.currentPrefix) },
                onCancel: { vm.cancelLoading() },
                searchPlaceholder: "Search loaded objects"
            )
            HStack {
                Button {
                    guard let context = transferContext else { return }
                    transferVM.chooseUpload(context: context) { await S3FilePanels.openFile(locale: locale) }
                } label: {
                    Label(L10n.text("Upload File", locale: locale), systemImage: "arrow.up.doc")
                }
                .disabled(!transferVM.canStart || transferContext == nil)
                Text(L10n.text("or drop a file", locale: locale))
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if versionsVM != nil {
                    Button(L10n.text("Object versions", locale: locale)) {
                        if let object = vm.selectedObject { openVersions(object) }
                    }
                    .disabled(vm.selectedObject == nil || vm.selectedObject?.isPrefix == true || transferContext?.isValid != true)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
            S3TransferStatusView(vm: transferVM)
            S3BreadcrumbView(bucket: bucketName, prefix: vm.currentPrefix) { prefix in
                vm.navigateToPrefix(bucket: bucketName, prefix: prefix)
            }
            Divider()

            List(filteredObjects, selection: objectSelection) { object in
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
                .tag(object.id)
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
                        if versionsVM != nil {
                            Button(L10n.text("Object versions", locale: locale)) { openVersions(object) }
                                .disabled(transferContext?.isValid != true)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if !vm.isLoading, let error = vm.error {
                    EmptyStateView(text: error, icon: "exclamationmark.triangle")
                } else if !vm.isLoading && filteredObjects.isEmpty {
                    EmptyStateView(text: vm.hasMoreObjects
                                   ? "No matching objects in the pages loaded so far. Use Load more to continue."
                                   : vm.objects.isEmpty ? "No objects at this prefix" : "No matching objects", icon: "folder")
                }
            }
            S3ObjectPaginationFooter(vm: vm, bucket: bucketName, visibleObjectCount: filteredObjects.count)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let context = transferContext else { return false }
            return transferVM.receiveUploadDrop(context: context, numberOfFiles: providers.count) {
                try await S3FileDrop.load(providers)
            }
        }
        .overlay {
            if isDropTargeted, transferVM.canStart, let context = transferContext {
                S3UploadDropOverlay(context: context).allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showsVersions) {
            if let versionsVM { S3VersionsView(vm: versionsVM) }
        }
        .onChange(of: transferContext) { _ in
            showsVersions = false
            versionsVM?.reset()
        }
        .onChange(of: transferPrefixIdentity) { _ in
            showsVersions = false
            versionsVM?.reset()
        }
        .onDisappear {
            showsVersions = false
            versionsVM?.reset()
        }
    }

    private func openVersions(_ object: S3ObjectModel) {
        guard let versionsVM, let transferContext, transferContext.isValid,
              transferContext.bucket == bucketName, !object.isPrefix,
              vm.objects.contains(object) else { return }
        versionsVM.configure(context: transferContext, key: object.key)
        showsVersions = true
    }

    private var objectSelection: Binding<Data?> {
        Binding(get: { vm.selectedObject?.id }, set: { id in
            vm.selectedObject = id.flatMap { key in vm.objects.first { $0.id == key } }
        })
    }

    private func lastComponent(of key: String) -> String {
        let name = S3Breadcrumb.path(for: key).last?.name ?? key
        return name.isEmpty ? "/" : name
    }
}

struct S3UploadDropOverlay: View {
    @Environment(\.locale) private var locale
    let context: S3TransferContext

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            Rectangle().strokeBorder(Color.accentColor, lineWidth: 1)
            VStack(spacing: WorkspaceLayout.controlSpacing) {
                Label(L10n.text("Drop a file to upload here", locale: locale), systemImage: "arrow.up.doc")
                    .font(.headline)
                Text("s3://" + context.bucket + "/" + context.prefix)
                    .font(.caption).foregroundColor(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .help("s3://" + context.bucket + "/" + context.prefix)
            }.padding(WorkspaceLayout.contextSpacing)
        }
    }
}
