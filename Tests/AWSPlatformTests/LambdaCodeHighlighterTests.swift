import XCTest
@testable import AWSPlatform

final class LambdaCodeHighlighterTests: XCTestCase {
    func testTokenizationPreservesUnicodeBlankLinesAndLongLines() throws {
        let content = "\n\nlet 👩🏽‍💻 = \"中文 e\u{301} é 🧑‍👩‍👧\"\r\n\n"
            + String(repeating: "长行\t ", count: 10_000) + "\n"
        let segments = try LambdaCodeHighlighter.tokenize(content, path: "源码.SWIFT")
        XCTAssertEqual(Array(segments.map(\.text).joined().utf8), Array(content.utf8))
        XCTAssertTrue(segments.contains { $0.kind == .keyword && $0.text == "let" })
        XCTAssertTrue(segments.contains { $0.kind == .string && $0.text.contains("中文") })
    }

    func testTokenClassificationKeepsCommentsInsideStrings() throws {
        let segments = try LambdaCodeHighlighter.tokenize(
            "let value = \"a//b\" // comment\n# heading\nreturn 42.5", path: "index.js"
        )
        XCTAssertEqual(segments.filter { $0.kind == .keyword }.map(\.text), ["let", "return"])
        XCTAssertEqual(segments.filter { $0.kind == .string }.map(\.text), ["\"a//b\""])
        XCTAssertEqual(segments.filter { $0.kind == .comment }.map(\.text), ["// comment", "# heading"])
        XCTAssertEqual(segments.filter { $0.kind == .number }.map(\.text), ["42.5"])
    }

    func testUnhighlightedFilesAndEmptyContentRemainExact() throws {
        let content = "\nlet text = '引用'\n\n"
        XCTAssertEqual(
            try LambdaCodeHighlighter.tokenize(content, path: "README.md"),
            [.init(text: content, kind: .plain)]
        )
        XCTAssertEqual(try LambdaCodeHighlighter.tokenize("", path: "empty.swift"), [])
    }

    func testCancelledTokenizationDoesNotProduceAResult() async {
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LambdaCodeHighlighter.tokenize("let value = 42", path: "main.swift")
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled lexer must not return a display result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testLargeHighlightedSourceResolvesWithoutADeepConcatenationStack() async {
        let content = String(repeating: "let value = \"中文\" // note 123\n", count: 10_000)
        let value = request(content: content)
        let state = LambdaCodePreviewState()
        await state.update(value)
        guard let text = state.text(for: value) else {
            XCTFail("Large source must produce a preview")
            return
        }
        // Resolving the former 12,000-node linear Text tree overflowed the
        // stack at only 2,000 lines; construction alone did not expose it.
        let description = String(reflecting: text)
        XCTAssertFalse(description.isEmpty)
        XCTAssertEqual(state.cachedSource, value.source)
        await state.update(value)
        XCTAssertEqual(state.parseCount, 1)
        XCTAssertEqual(state.renderCount, 1)
        state.cancel()
        XCTAssertNil(state.renderedText)
        XCTAssertNil(state.cachedSource)
    }

    @MainActor
    func testRepeatedDisplayReusesTokensAndTextAndThemeOnlyRenders() async {
        let state = LambdaCodePreviewState()
        let light = request()
        for _ in 0..<10 {
            await state.update(light)
            XCTAssertNotNil(state.text(for: light))
        }
        XCTAssertEqual(state.parseCount, 1)
        XCTAssertEqual(state.renderCount, 1)

        let dark = request(appearance: .dark)
        await state.update(dark)
        XCTAssertEqual(state.parseCount, 1)
        XCTAssertEqual(state.renderCount, 2)
        XCTAssertNil(state.text(for: light))
        XCTAssertNotNil(state.text(for: dark))
    }

    @MainActor
    func testPathContentAndFunctionChangesReplaceTheOnlyCachedFile() async {
        let state = LambdaCodePreviewState()
        let first = request()
        await state.update(first)
        let changedContent = request(content: "return 2")
        await state.update(changedContent)
        let changedPath = request(path: "other.swift", content: "return 2")
        await state.update(changedPath)
        let changedFunction = request(function: "function-b", path: "other.swift", content: "return 2")
        await state.update(changedFunction)
        XCTAssertEqual(state.parseCount, 4)
        XCTAssertEqual(state.cachedSource, changedFunction.source)
        XCTAssertNil(state.text(for: first))
        XCTAssertNil(state.text(for: changedPath))

        await state.update(first)
        XCTAssertEqual(state.parseCount, 5, "Previously viewed source is not retained in a multi-file cache")
        await state.update(nil)
        XCTAssertNil(state.cachedSource)
        XCTAssertNil(state.renderedText)
    }

    @MainActor
    func testCanonicallyEquivalentSourceAndPathsStillInvalidateByBytes() async {
        let state = LambdaCodePreviewState()
        let composed = request(path: "é.swift", content: "let value = \"é\"")
        let decomposed = request(path: "e\u{301}.swift", content: "let value = \"e\u{301}\"")
        XCTAssertEqual(composed.source.content, decomposed.source.content)
        XCTAssertNotEqual(composed.source, decomposed.source)
        await state.update(composed)
        await state.update(decomposed)
        XCTAssertEqual(state.parseCount, 2)
        XCTAssertNotNil(state.text(for: decomposed))
        XCTAssertNil(state.text(for: composed))

        // Equal UTF-8 counts with canonically reordered combining marks must
        // also update copied text instead of reusing the previous file.
        let ordered = request(content: "a\u{300}\u{315}")
        let reordered = request(content: "a\u{315}\u{300}")
        XCTAssertEqual(ordered.source.content, reordered.source.content)
        XCTAssertEqual(ordered.source.content.utf8.count, reordered.source.content.utf8.count)
        XCTAssertNotEqual(ordered.source, reordered.source)
    }

    @MainActor
    func testInFlightThemeChangeUsesIndependentWorkerAndRejectsOldCancellation() async {
        let gate = CodeHighlightGate()
        let state = LambdaCodePreviewState { content, _ in
            let result = try await gate.tokenize(content: content, wasMainThread: Self.isMainThread())
            try Task.checkCancellation()
            return result
        }
        let light = request()
        let dark = request(appearance: .dark)
        let oldConsumer = Task { await state.update(light) }
        await gate.waitForEntries(1)
        let newConsumer = Task { await state.update(dark) }
        await gate.waitForEntries(2)
        oldConsumer.cancel()

        await gate.complete(1)
        await newConsumer.value
        XCTAssertEqual(state.parseCount, 2)
        XCTAssertEqual(state.renderCount, 1)
        XCTAssertNotNil(state.text(for: dark))
        XCTAssertNil(state.text(for: light))

        await gate.complete(0)
        await oldConsumer.value
        XCTAssertEqual(state.renderCount, 1)
        XCTAssertNotNil(state.text(for: dark))
        let mainThreadObservations = await gate.mainThreadObservations
        XCTAssertEqual(mainThreadObservations, [false, false], "Lexing must leave the UI thread")
    }

    @MainActor
    func testABARejectsLateFirstGenerationEvenWhenTheRequestMatchesAgain() async {
        let gate = CodeHighlightGate()
        let state = LambdaCodePreviewState { content, _ in
            try await gate.tokenize(content: content, wasMainThread: Self.isMainThread())
        }
        let a = request()
        let b = request(path: "b.swift", content: "return 2")
        let first = Task { await state.update(a) }
        await gate.waitForEntries(1)
        let middle = Task { await state.update(b) }
        await gate.waitForEntries(2)
        let last = Task { await state.update(a) }
        await gate.waitForEntries(3)

        await gate.complete(0)
        await first.value
        XCTAssertNil(state.renderedText)
        await gate.complete(2)
        await last.value
        XCTAssertNotNil(state.text(for: a))
        await gate.complete(1)
        await middle.value
        XCTAssertEqual(state.parseCount, 3)
        XCTAssertEqual(state.renderCount, 1)
        XCTAssertNotNil(state.text(for: a))
        XCTAssertNil(state.text(for: b))
    }

    @MainActor
    func testClearingOrCancellingDoesNotRepopulatePreviewFromLateSuccess() async {
        let gate = CodeHighlightGate()
        let state = LambdaCodePreviewState { content, _ in
            try await gate.tokenize(content: content, wasMainThread: Self.isMainThread())
        }
        let value = request()
        let first = Task { await state.update(value) }
        await gate.waitForEntries(1)
        state.cancel()
        await gate.complete(0)
        await first.value
        XCTAssertNil(state.cachedSource)
        XCTAssertNil(state.renderedText)
        XCTAssertEqual(state.renderCount, 0)

        let second = Task { await state.update(value) }
        await gate.waitForEntries(2)
        second.cancel()
        await gate.complete(1)
        await second.value
        XCTAssertNil(state.cachedSource)
        XCTAssertNil(state.renderedText)
        XCTAssertEqual(state.renderCount, 0)
    }

    @MainActor
    func testCancelledNilConsumerCannotClearNewerRenderedSource() async {
        let state = LambdaCodePreviewState()
        let current = request(function: "current-function")
        await state.update(current)

        let staleConsumer = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await state.update(nil)
        }
        await staleConsumer.value
        XCTAssertEqual(state.cachedSource, current.source)
        XCTAssertNotNil(state.text(for: current))
        XCTAssertEqual(state.parseCount, 1)
        XCTAssertEqual(state.renderCount, 1)

        await state.update(nil)
        XCTAssertNil(state.cachedSource)
        XCTAssertNil(state.renderedText)
    }

    private nonisolated static func isMainThread() -> Bool {
        Thread.isMainThread
    }

    private func request(
        function: String = "function-a", path: String = "main.swift", content: String = "return 1",
        appearance: LambdaCodeHighlighter.Appearance = .light
    ) -> LambdaCodeHighlightRequest {
        .init(source: .init(functionID: function, path: path, content: content), appearance: appearance)
    }
}

/// Intentionally ignores cancellation, like a late synchronous lexer completion.
private actor CodeHighlightGate {
    private struct Entry {
        let content: String
        let continuation: CheckedContinuation<[LambdaCodeHighlighter.Segment], Error>
    }
    private var entries: [Entry] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var mainThreadObservations: [Bool] = []

    func tokenize(content: String, wasMainThread: Bool) async throws -> [LambdaCodeHighlighter.Segment] {
        try await withCheckedThrowingContinuation { continuation in
            entries.append(Entry(content: content, continuation: continuation))
            mainThreadObservations.append(wasMainThread)
            let ready = waiters.filter { entries.count >= $0.0 }
            waiters.removeAll { entries.count >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForEntries(_ count: Int) async {
        if entries.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func complete(_ index: Int) {
        let entry = entries[index]
        entry.continuation.resume(returning: [.init(text: entry.content, kind: .plain)])
    }
}
