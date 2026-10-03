import XCTest
@testable import AWSPlatform

final class MonitoringDisplayTests: XCTestCase {
    func testChartTimeAndDetailedTimeBothUseUTC() {
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        XCTAssertEqual(MonitoringDisplay.time(date), "04:00")
        XCTAssertEqual(MonitoringDisplay.dateTime(date), "2026-10-03 04:00:00 UTC")
    }
}
