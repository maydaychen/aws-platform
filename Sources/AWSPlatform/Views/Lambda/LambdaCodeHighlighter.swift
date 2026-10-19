import Foundation
import SwiftUI

/// A pure, cancellable lexer. The result contains only the current file's text.
enum LambdaCodeHighlighter {
    enum Kind: Equatable, Sendable {
        case plain, comment, string, number, keyword
    }

    enum Appearance: Equatable, Sendable {
        case light, dark
    }

    struct Segment: Equatable, Sendable {
        let text: String
        let kind: Kind
    }

    static func tokenize(_ content: String, path: String) throws -> [Segment] {
        try Task.checkCancellation()
        guard highlightedExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
              let expression else {
            return [Segment(text: content, kind: .plain)]
        }

        var segments: [Segment] = []
        var cursor = content.startIndex
        var cancelled = false
        expression.enumerateMatches(
            in: content, range: NSRange(content.startIndex..<content.endIndex, in: content)
        ) { match, _, stop in
            if Task.isCancelled {
                cancelled = true
                stop.pointee = true
                return
            }
            guard let match, let range = Range(match.range, in: content) else { return }
            if cursor < range.lowerBound {
                segments.append(Segment(text: String(content[cursor..<range.lowerBound]), kind: .plain))
            }
            let token = String(content[range])
            segments.append(Segment(text: token, kind: kind(for: token)))
            cursor = range.upperBound
        }
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
        if cursor < content.endIndex {
            segments.append(Segment(text: String(content[cursor...]), kind: .plain))
        }
        return segments
    }

    /// Construct SwiftUI's selectable Text once per file / appearance change.
    static func render(_ segments: [Segment], appearance: Appearance) -> Text {
        guard !segments.isEmpty else { return Text("") }

        func renderRange(_ range: Range<Int>) -> Text {
            guard range.count == 1 else {
                let middle = range.lowerBound + range.count / 2
                return renderRange(range.lowerBound..<middle) + renderRange(middle..<range.upperBound)
            }
            let segment = segments[range.lowerBound]
            let text = Text(segment.text)
            guard let color = color(for: segment.kind, appearance: appearance) else {
                return text
            }
            return text.foregroundColor(color)
        }

        // SwiftUI recursively resolves concatenated Text storage. Keep the
        // tree shallow even for source files with thousands of colored tokens.
        return renderRange(segments.indices)
    }

    private static func kind(for token: String) -> Kind {
        if token.hasPrefix("//") || token.hasPrefix("#") { return .comment }
        if token.hasPrefix("\"") || token.hasPrefix("'") { return .string }
        if token.first?.isNumber == true { return .number }
        return .keyword
    }

    private static func color(for kind: Kind, appearance: Appearance) -> Color? {
        switch kind {
        case .plain: return nil
        case .comment: return .secondary
        case .string: return appearance == .dark ? .orange : .brown
        case .number: return .blue
        case .keyword: return .purple
        }
    }

    private static let expression = try? NSRegularExpression(
        pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|//[^\n]*|#[^\n]*|\b(?:actor|async|await|break|case|catch|class|const|continue|def|do|else|enum|extension|false|for|from|func|function|guard|if|import|in|interface|internal|let|nil|null|private|protocol|public|return|static|struct|switch|throw|throws|true|try|var|while)\b|\b\d+(?:\.\d+)?\b"#
    )

    private static let highlightedExtensions: Set<String> = [
        "c", "cpp", "cs", "go", "h", "java", "js", "jsx", "kt", "mjs",
        "php", "py", "rb", "rs", "sh", "swift", "ts", "tsx"
    ]
}
