import SwiftUI

struct LambdaCodeHighlightRequest: Equatable, Sendable {
    struct Source: Equatable, Sendable {
        let functionID: String
        let path: String
        let content: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            sameBytes(lhs.functionID, rhs.functionID)
                && sameBytes(lhs.path, rhs.path)
                && sameBytes(lhs.content, rhs.content)
        }

        private static func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
            // Native String copies share storage, so ordinary body updates take
            // the pointer fast path. Distinct buffers compare exact source bytes,
            // including canonically equivalent but differently encoded Unicode.
            let contiguous = lhs.utf8.withContiguousStorageIfAvailable { left in
                rhs.utf8.withContiguousStorageIfAvailable { right in
                    left.count == right.count && (
                        left.baseAddress == right.baseAddress || left.elementsEqual(right)
                    )
                }
            }
            return contiguous.flatMap { $0 } ?? lhs.utf8.elementsEqual(rhs.utf8)
        }
    }

    let source: Source
    let appearance: LambdaCodeHighlighter.Appearance
}

/// One lexical result and one rendered Text, never a cache of visited files.
@MainActor
final class LambdaCodePreviewState: ObservableObject {
    typealias Tokenizer = @Sendable (String, String) async throws -> [LambdaCodeHighlighter.Segment]

    @Published private(set) var renderedText: Text?
    private(set) var parseCount = 0
    private(set) var renderCount = 0
    private(set) var cachedSource: LambdaCodeHighlightRequest.Source?

    private let tokenizer: Tokenizer
    private var segments: [LambdaCodeHighlighter.Segment]?
    private var requested: LambdaCodeHighlightRequest?
    private var renderedRequest: LambdaCodeHighlightRequest?
    private var generation = UUID()
    private var worker: Task<[LambdaCodeHighlighter.Segment], Error>?

    init(tokenizer: @escaping Tokenizer = { content, path in
        try LambdaCodeHighlighter.tokenize(content, path: path)
    }) {
        self.tokenizer = tokenizer
    }

    func text(for request: LambdaCodeHighlightRequest) -> Text? {
        renderedRequest == request ? renderedText : nil
    }

    func update(_ request: LambdaCodeHighlightRequest?) async {
        guard !Task.isCancelled else { return }
        guard let request else {
            cancel()
            return
        }
        if renderedRequest == request { return }

        generation = UUID()
        let currentGeneration = generation
        requested = request

        if cachedSource == request.source, let segments {
            render(segments, request: request)
            return
        }

        renderedText = nil
        renderedRequest = nil
        cachedSource = nil
        segments = nil

        worker?.cancel()
        let tokenizer = tokenizer
        let source = request.source
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await tokenizer(source.content, source.path)
        }
        worker = task
        parseCount += 1

        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard !Task.isCancelled, generation == currentGeneration, requested == request else { return }
            worker = nil
            cachedSource = request.source
            segments = result
            render(result, request: request)
        } catch {
            guard generation == currentGeneration, requested == request else { return }
            worker = nil
            // Cancellation never installs a late result. Other lexer failures
            // can still show the original selectable source without highlighting.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            let plain = [LambdaCodeHighlighter.Segment(text: request.source.content, kind: .plain)]
            cachedSource = request.source
            segments = plain
            render(plain, request: request)
        }
    }

    func cancel() {
        generation = UUID()
        worker?.cancel()
        worker = nil
        requested = nil
        renderedRequest = nil
        cachedSource = nil
        segments = nil
        renderedText = nil
    }

    private func render(_ segments: [LambdaCodeHighlighter.Segment], request: LambdaCodeHighlightRequest) {
        renderedText = LambdaCodeHighlighter.render(segments, appearance: request.appearance)
        renderedRequest = request
        renderCount += 1
    }
}
