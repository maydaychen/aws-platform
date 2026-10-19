import Foundation
import SwiftUI
import XCTest
@testable import AWSPlatform

final class PerformanceWorkloadTests: XCTestCase {
    @MainActor
    func testRepeatedCodePreviewParsesAndRendersOnlyOnce() async throws {
        // Use a scale both versions can resolve; the large-current-render
        // regression lives in LambdaCodeHighlighterTests.
        let content = String(repeating: "let value = \"中文\" // note 123\n", count: 100)
        let request = LambdaCodeHighlightRequest(
            source: .init(functionID: "mock-function", path: "index.swift", content: content),
            appearance: .dark
        )
        let baseline = medianMilliseconds {
            for _ in 0..<10 {
                guard let text = baselineHighlightedText(content) else {
                    return XCTFail("Baseline must produce a preview")
                }
                withExtendedLifetime(text) {}
            }
        }
        var samples: [Double] = []
        for _ in 0..<3 {
            let state = LambdaCodePreviewState()
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<10 { await state.update(request) }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertEqual(state.parseCount, 1)
            XCTAssertEqual(state.renderCount, 1)
            XCTAssertNotNil(state.text(for: request))
            state.cancel()
            XCTAssertNil(state.cachedSource)
        }
        print("PERFORMANCE source_preview bytes=\(content.utf8.count) updates=10 runs=3 baseline_parses=10 cached_parses=1 baseline_ms=\(baseline) cached_ms=\(samples.sorted()[1])")
    }

    @MainActor
    func testBrowsingTwentyFunctionsRetainsOnlyCurrentSourcePayload() async {
        let payload = String(repeating: "x", count: 100 * 1_024)
        let source: (LambdaFunctionModel) -> [LambdaCodeFile] = { function in
            [.init(path: "index.py", content: "# \(function.functionName)\n" + payload, isBinary: false)]
        }
        let vm = LambdaViewModel(codeLoader: { function in
            var updated = function
            updated.codeFiles = source(function)
            return updated
        })
        vm.functions = (0..<20).map { function("mock-\($0)") }
        var baseline = vm.functions
        for index in baseline.indices {
            let selected = vm.functions[index]
            vm.selectedFunction = selected
            await vm.loadCode(for: selected.functionName)
            baseline[index].codeFiles = source(selected)
        }
        let oldBytes = retainedSourceBytes(baseline)
        let currentBytes = retainedSourceBytes(vm.functions)
        XCTAssertEqual(vm.functions.filter { !$0.codeFiles.isEmpty }.count, 1)
        XCTAssertEqual(currentBytes, retainedSourceBytes([vm.selectedFunction].compactMap { $0 }))
        XCTAssertLessThanOrEqual(currentBytes, payload.utf8.count + 20)
        XCTAssertGreaterThan(oldBytes, currentBytes)
        print("PERFORMANCE source_retention functions=20 baseline_retained_utf8=\(oldBytes) current_retained_utf8=\(currentBytes)")
    }

    func testS3AppendWorkloadsMatchThePinnedBaseline() {
        for pageCount in [1, 10, 50] {
            let total = pageCount * 1_000
            let existing = (0..<(total - 1_000)).map(object)
            let page = ((total - 1_000)..<total).reversed().map(object)
            let expected = baselineMerge(existing, with: page)
            let actual = S3ObjectListing.mergeSorted(existing, with: page)
            XCTAssertEqual(actual, expected)

            let baseline = medianMilliseconds {
                let result = baselineMerge(existing, with: page)
                XCTAssertEqual(result.count, total)
            }
            let incremental = medianMilliseconds {
                let result = S3ObjectListing.mergeSorted(existing, with: page)
                XCTAssertEqual(result.count, total)
            }
            print("PERFORMANCE s3_append result_rows=\(total) page_rows=1000 runs=3 baseline_ms=\(baseline) incremental_ms=\(incremental)")
        }
    }

    private func object(_ index: Int) -> S3ObjectModel {
        .init(key: String(format: "item-%08d", index), size: Int64(index),
              lastModified: nil, storageClass: "STANDARD", isPrefix: false)
    }

    private func function(_ name: String) -> LambdaFunctionModel {
        .init(functionName: name, runtime: "python3.12", state: "Active",
              lastUpdateStatus: nil, lastModified: nil, memorySize: nil, arn: nil,
              handler: nil, role: nil, codeSize: nil, timeout: nil, environment: [:],
              vpcConfig: nil, packageType: "Zip", imageUri: nil, tags: [:],
              codeLocation: nil, codeFiles: [])
    }

    private func retainedSourceBytes(_ functions: [LambdaFunctionModel]) -> Int {
        functions.reduce(0) { total, function in
            total + function.codeFiles.reduce(0) { $0 + ($1.content?.utf8.count ?? 0) }
        }
    }

    // The pre-change view compiled this expression and rebuilt Text on every body evaluation.
    @MainActor
    private func baselineHighlightedText(_ content: String) -> Text? {
        let pattern = #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|//[^\n]*|#[^\n]*|\b(?:actor|async|await|break|case|catch|class|const|continue|def|do|else|enum|extension|false|for|from|func|function|guard|if|import|in|interface|internal|let|nil|null|private|protocol|public|return|static|struct|switch|throw|throws|true|try|var|while)\b|\b\d+(?:\.\d+)?\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        var result = Text("")
        var cursor = content.startIndex
        for match in expression.matches(in: content, range: NSRange(content.startIndex..<content.endIndex, in: content)) {
            guard let range = Range(match.range, in: content) else { continue }
            if cursor < range.lowerBound { result = result + Text(String(content[cursor..<range.lowerBound])) }
            let token = String(content[range])
            let color: Color
            if token.hasPrefix("//") || token.hasPrefix("#") { color = .secondary }
            else if token.hasPrefix("\"") || token.hasPrefix("'") { color = .orange }
            else if token.first?.isNumber == true { color = .blue }
            else { color = .purple }
            result = result + Text(token).foregroundColor(color)
            cursor = range.upperBound
        }
        if cursor < content.endIndex { result = result + Text(String(content[cursor...])) }
        return result
    }

    // Exact merge strategy from 7a65d9a, retained only as a differential benchmark oracle.
    private func baselineMerge(_ existing: [S3ObjectModel], with page: [S3ObjectModel]) -> [S3ObjectModel] {
        var rows: [Data: S3ObjectModel] = [:]
        for object in existing + page {
            if rows[object.id]?.isPrefix == true, !object.isPrefix { continue }
            rows[object.id] = object
        }
        return rows.values.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    }

    private func medianMilliseconds(_ operation: () -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            operation()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        return samples.sorted()[1]
    }
}
