import SwiftUI

@MainActor
struct LambdaCodeView: View {
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    let function: LambdaFunctionModel

    @State private var selectedFileID: LambdaCodeFile.ID?
    @StateObject private var preview = LambdaCodePreviewState()

    var body: some View {
        Group {
            if function.packageType == "Image" {
                containerImageView
            } else if function.codeFiles.isEmpty {
                EmptyStateView(text: "Code not loaded")
            } else {
                HSplitView {
                    List(function.codeFiles, selection: $selectedFileID) { file in
                        Label(file.path, systemImage: file.isBinary ? "doc" : "doc.text")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(file.path)
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 140, idealWidth: 180, maxWidth: 240)

                    codePreview
                        .frame(minWidth: 300)
                }
                .onAppear(perform: selectFirstFileIfNeeded)
                .onChange(of: function.functionName) { _ in
                    selectedFileID = function.codeFiles.first?.id
                }
                .onChange(of: function.codeFiles) { _ in
                    selectFirstFileIfNeeded()
                }
            }
        }
        .task(id: previewRequest) {
            await preview.update(previewRequest)
        }
        .onDisappear { preview.cancel() }
    }

    private var containerImageView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Container Image", locale: locale))
                .font(.headline)
            Text(L10n.text("This function is packaged as a container image.", locale: locale))
                .foregroundColor(.secondary)
            if let imageUri = function.imageUri {
                Text(imageUri)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }

    @ViewBuilder
    private var codePreview: some View {
        if let file = selectedFile {
            VStack(alignment: .leading, spacing: 0) {
                Text(file.path)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.path)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                Divider()
                if file.content != nil, let request = previewRequest {
                    ScrollView([.horizontal, .vertical]) {
                        if let text = preview.text(for: request) {
                            text
                                .font(.system(size: 12, design: .monospaced))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(12)
                        } else {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(12)
                        }
                    }
                } else {
                    EmptyStateView(text: "Binary or large file preview is unavailable")
                }
            }
        } else {
            EmptyStateView(text: "Select a source file")
        }
    }

    private var selectedFile: LambdaCodeFile? {
        guard let selectedFileID else { return nil }
        return function.codeFiles.first { $0.id == selectedFileID }
    }

    private func selectFirstFileIfNeeded() {
        guard selectedFile == nil else { return }
        selectedFileID = function.codeFiles.first?.id
    }

    private var previewRequest: LambdaCodeHighlightRequest? {
        guard let file = selectedFile, let content = file.content else { return nil }
        return LambdaCodeHighlightRequest(
            source: .init(functionID: function.arn ?? function.functionName, path: file.path, content: content),
            appearance: colorScheme == .dark ? .dark : .light
        )
    }
}
