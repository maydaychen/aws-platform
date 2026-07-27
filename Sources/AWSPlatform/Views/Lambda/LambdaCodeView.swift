import SwiftUI

struct LambdaCodeView: View {
    let function: LambdaFunctionModel

    @State private var selectedFileID: LambdaCodeFile.ID?

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
                    }
                    .frame(minWidth: 180, idealWidth: 240)

                    codePreview
                        .frame(minWidth: 320)
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
    }

    private var containerImageView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Container Image")
                .font(.headline)
            Text("This function is packaged as a container image.")
                .foregroundColor(.secondary)
            if let imageUri = function.imageUri {
                Text(imageUri)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor))
                Divider()
                if let content = file.content {
                    ScrollView([.horizontal, .vertical]) {
                        highlightedText(content, path: file.path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
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

    private func highlightedText(_ content: String, path: String) -> Text {
        guard Self.highlightedExtensions.contains(
            URL(fileURLWithPath: path).pathExtension.lowercased()
        ) else {
            return Text(content)
        }

        let pattern = #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|//[^\n]*|#[^\n]*|\b(?:actor|async|await|break|case|catch|class|const|continue|def|do|else|enum|extension|false|for|from|func|function|guard|if|import|in|interface|internal|let|nil|null|private|protocol|public|return|static|struct|switch|throw|throws|true|try|var|while)\b|\b\d+(?:\.\d+)?\b"#

        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return Text(content)
        }

        var result = Text("")
        var cursor = content.startIndex
        let range = NSRange(content.startIndex..<content.endIndex, in: content)

        for match in expression.matches(in: content, range: range) {
            guard let matchRange = Range(match.range, in: content) else { continue }
            if cursor < matchRange.lowerBound {
                result = result + Text(String(content[cursor..<matchRange.lowerBound]))
            }

            let token = String(content[matchRange])
            result = result + Text(token).foregroundColor(Self.color(for: token))
            cursor = matchRange.upperBound
        }

        if cursor < content.endIndex {
            result = result + Text(String(content[cursor...]))
        }
        return result
    }

    private static func color(for token: String) -> Color {
        if token.hasPrefix("//") || token.hasPrefix("#") {
            return .green
        }
        if token.hasPrefix("\"") || token.hasPrefix("'") {
            return .orange
        }
        if token.first?.isNumber == true {
            return .blue
        }
        return .purple
    }

    private static let highlightedExtensions: Set<String> = [
        "c", "cpp", "cs", "go", "h", "java", "js", "jsx", "kt", "mjs",
        "php", "py", "rb", "rs", "sh", "swift", "ts", "tsx"
    ]
}
