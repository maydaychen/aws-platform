import XCTest
@testable import AWSPlatform

final class CostModelsTests: XCTestCase {
    func testPresetsUseCompletedUTCDaysAndPreviousMonthCrossesYear() throws {
        let now = try XCTUnwrap(CostDates.date("2026-01-01"))
        let current = CostPeriod.thisMonth.range(now: now)
        XCTAssertTrue(current.isEmpty)
        XCTAssertEqual(current.startString, "2026-01-01")
        let previous = CostPeriod.lastMonth.range(now: now)
        XCTAssertEqual(previous.startString, "2025-12-01")
        XCTAssertEqual(previous.endString, "2026-01-01")
        XCTAssertEqual(CostDates.string(CostDates.inclusiveEnd(of: previous)), "2025-12-31")
    }

    func testLeapDayAndLast30DaysAreCalendarBased() throws {
        let now = try XCTUnwrap(CostDates.date("2024-03-01"))
        let previous = CostPeriod.lastMonth.range(now: now)
        XCTAssertEqual(previous.startString, "2024-02-01")
        XCTAssertEqual(CostDates.string(CostDates.inclusiveEnd(of: previous)), "2024-02-29")
        XCTAssertEqual(CostPeriod.last30Days.range(now: now).startString, "2024-01-31")
    }

    func testInvalidAndFutureDateRangesAreRejected() throws {
        let now = try XCTUnwrap(CostDates.date("2026-10-03"))
        let tomorrow = try XCTUnwrap(CostDates.date("2026-10-04"))
        let old = try XCTUnwrap(CostDates.date("2025-09-30"))
        for range in [CostDateRange(start: tomorrow, end: now), CostDateRange(start: now, end: tomorrow),
                      CostDateRange(start: old, end: now)] {
            XCTAssertNotNil(CostQuery(range: range, region: nil, referenceDate: now).validationMessage)
        }
        XCTAssertNil(CostDates.date("2026-02-30"))
        XCTAssertNil(CostDates.date("2026-2-3"))
    }

    func testCostQueryUsesCostRegionAndNormalizedReferenceDay() throws {
        let now = try XCTUnwrap(CostDates.date("2026-10-03"))
        let range = CostPeriod.thisMonth.range(now: now)
        let first = CostQuery(range: range, region: nil, referenceDate: now)
        let sameDay = CostQuery(range: range, region: nil, referenceDate: now.addingTimeInterval(3600))
        let filtered = CostQuery(range: range, region: "ap-southeast-1", referenceDate: now)
        XCTAssertEqual(first, sameDay)
        XCTAssertNotEqual(first, filtered)
        XCTAssertEqual(first.summaryRange.startString, "2026-09-01")
        XCTAssertEqual(first.summaryRange.endString, "2026-10-03")
        XCTAssertNil(first.validationMessage)
    }
}
