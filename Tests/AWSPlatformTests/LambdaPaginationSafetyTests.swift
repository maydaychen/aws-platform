import XCTest
@testable import AWSPlatform

final class LambdaPaginationSafetyTests: XCTestCase {
    @MainActor
    func testRepeatedAndCyclicMarkersFailWithoutReturningPartialResults() async {
        for markers in [["same", "same"], ["first", "second", "first"], [" \t"]] {
            var calls = 0
            var result: [Int]?
            do {
                result = try await LambdaPaginator.collect { _ in
                    let marker = markers[calls]
                    calls += 1
                    return ([calls], marker)
                }
                XCTFail("Invalid marker sequence must fail")
            } catch {
                XCTAssertEqual(error as? LambdaDetailError, .incompletePagination)
            }
            XCTAssertNil(result)
            XCTAssertEqual(calls, markers.count)
        }
    }

    @MainActor
    func testNilAndEmptyMarkersFinishAfterFinalPage() async throws {
        for finalMarker in [nil, ""] as [String?] {
            var calls = 0
            let result: [Int] = try await LambdaPaginator.collect(maxPages: 2) { marker in
                calls += 1
                if marker == nil { return ([1], "next") }
                XCTAssertEqual(marker, "next")
                return ([2], finalMarker)
            }
            XCTAssertEqual(result, [1, 2])
            XCTAssertEqual(calls, 2)
        }
    }

    @MainActor
    func testEmptyPageWithNextMarkerDoesNotTruncateList() async throws {
        var markers: [String?] = []
        let result: [Int] = try await LambdaPaginator.collect { marker in
            markers.append(marker)
            return marker == nil ? ([], "next") : ([2], nil)
        }
        XCTAssertEqual(markers, [nil, "next"])
        XCTAssertEqual(result, [2])
    }

    @MainActor
    func testPageLimitFailsBeforeFetchingAnotherPage() async {
        var calls = 0
        var result: [Int]?
        do {
            result = try await LambdaPaginator.collect(maxPages: 2) { _ in
                calls += 1
                return ([calls], "page-\(calls)")
            }
            XCTFail("A remaining page at the limit must fail")
        } catch {
            XCTAssertEqual(error as? LambdaDetailError, .incompletePagination)
        }
        XCTAssertNil(result)
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testInvalidPageLimitsMakeNoRequests() async {
        for limit in [0, -1] {
            var calls = 0
            do {
                let _: [Int] = try await LambdaPaginator.collect(maxPages: limit) { _ in
                    calls += 1
                    return ([1], nil)
                }
                XCTFail("Invalid page limit must fail")
            } catch {
                XCTAssertEqual(error as? LambdaDetailError, .incompletePagination)
            }
            XCTAssertEqual(calls, 0)
        }
    }

    @MainActor
    func testLaterPageFailureDoesNotReturnFirstPage() async {
        var calls = 0
        var result: [Int]?
        do {
            result = try await LambdaPaginator.collect { _ in
                calls += 1
                if calls == 2 { throw LambdaPageTestError.failed }
                return ([1], "next")
            }
            XCTFail("Page failure must propagate")
        } catch {
            XCTAssertTrue(error is LambdaPageTestError)
        }
        XCTAssertNil(result)
        XCTAssertEqual(calls, 2)
    }

    @MainActor
    func testCancellationBeforeFirstPageMakesNoRequests() async {
        var calls = 0
        let request = Task { @MainActor in
            let _: [Int] = try await LambdaPaginator.collect { _ in
                calls += 1
                return ([1], nil)
            }
        }
        request.cancel()
        do {
            try await request.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testCancellationRejectsPageFromLoaderIgnoringCancellation() async {
        let gate = TestGate()
        var calls = 0
        let request = Task { @MainActor in
            try await LambdaPaginator.collect { _ in
                calls += 1
                await gate.wait()
                return ([1], nil as String?)
            }
        }
        await gate.waitForEntry()
        request.cancel()
        await gate.open()
        do {
            _ = try await request.value
            XCTFail("Late page must not escape cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }
}

private enum LambdaPageTestError: Error { case failed }
