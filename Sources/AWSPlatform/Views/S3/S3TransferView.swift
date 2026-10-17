import AppKit
import SwiftUI

@MainActor
enum S3FilePanels {
    static func openFile(locale: Locale) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("Choose File", locale: locale)
        return await present(panel)
    }

    static func saveFile(key: String, locale: Locale) async -> URL? {
        let panel = NSSavePanel()
        // Only suggest a filename; never append an S3 key to a local directory.
        let name = key.split(separator: "/").last.map(String.init) ?? "download"
        panel.nameFieldStringValue = name == "." || name == ".." ? "download" : name
        panel.canCreateDirectories = true
        panel.prompt = L10n.text("Download", locale: locale)
        return await present(panel)
    }

    private static func present(_ panel: NSSavePanel) async -> URL? {
        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                let completion: (NSApplication.ModalResponse) -> Void = { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
                if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
                else { panel.begin(completionHandler: completion) }
            }
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
    }
}

struct S3UploadConfirmationView: View {
    @Environment(\.locale) private var locale
    let intent: S3UploadIntent
    let onCancel: () -> Void
    let onConfirm: () -> Void
    private var isOverwrite: Bool { intent.overwriteETag != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text(isOverwrite ? "Overwrite S3 object?" : "Upload to S3?", locale: locale),
                  systemImage: isOverwrite ? "exclamationmark.triangle" : "arrow.up.doc")
                .font(.title2.weight(.semibold))
                .foregroundColor(isOverwrite ? .orange : .primary)
            ScrollView {
                DetailFieldRows(items: [
                    ("Profile", intent.context.scope.profile.name),
                    ("Account", intent.context.scope.accountID),
                    ("Bucket", intent.context.bucket),
                    ("Key", intent.key),
                    ("Local File", intent.file.url.path),
                    ("Size", intent.file.size.formatted(.byteCount(style: .file).locale(locale)))
                ])
            }.frame(height: WorkspaceLayout.s3ConfirmationDetailsHeight)
            Text(L10n.text(isOverwrite
                ? "Existing object metadata, tags and ACLs are not copied. This upload uses Bucket defaults. If versioning is enabled, AWS keeps the previous version."
                : "This writes a file to AWS using the displayed Profile. An existing object will require a separate overwrite confirmation.", locale: locale))
                .font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.text("Cancel", locale: locale), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L10n.text(isOverwrite ? "Overwrite" : "Upload", locale: locale), action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(isOverwrite ? .orange : .accentColor)
            }
        }
        .padding()
        .frame(width: WorkspaceLayout.s3ConfirmationWidth)
        .interactiveDismissDisabled()
    }
}

struct S3TransferStatusView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: S3TransferViewModel

    var body: some View {
        if vm.isBusy || vm.status != nil || vm.error != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.text(vm.error ?? vm.status ?? "", locale: locale))
                        .font(.caption)
                        .foregroundColor(vm.error == nil ? .secondary : .red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if vm.isBusy {
                        Button(L10n.text("Cancel", locale: locale)) { vm.cancel() }
                            .controlSize(.small)
                    }
                }
                if let recoveryURL = vm.completedDownload?.recoveryURL {
                    Text(L10n.format("Previous file saved at: %@", recoveryURL.path, locale: locale))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if vm.isBusy {
                    if let key = vm.activeKey {
                        Text(key).font(.caption).lineLimit(1).truncationMode(.middle).help(key)
                    }
                    if let fraction = vm.progress.fraction { ProgressView(value: fraction) }
                    else { ProgressView().controlSize(.small) }
                    if vm.progress.bytes > 0 {
                        Text(vm.progress.bytes.formatted(.byteCount(style: .file).locale(locale)))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
        }
    }
}
