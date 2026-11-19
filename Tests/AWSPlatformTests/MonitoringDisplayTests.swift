import XCTest
@testable import AWSPlatform

final class MonitoringDisplayTests: XCTestCase {
    func testChartTimeAndDetailedTimeBothUseUTC() {
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        XCTAssertEqual(MonitoringDisplay.time(date), "04:00")
        XCTAssertEqual(MonitoringDisplay.dateTime(date), "2026-10-03 04:00:00 UTC")
    }

    func testConcurrentClockAndTimestampFormattingAcrossUTCMidnight() async {
        let midnight = Date(timeIntervalSince1970: 1_791_000_000 - 14_400)
        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<64 {
                group.addTask {
                    let before = index.isMultiple(of: 2)
                    let date = midnight.addingTimeInterval(before ? -1 : 0)
                    return MonitoringDisplay.time(date) == (before ? "23:59" : "00:00")
                        && MonitoringDisplay.dateTime(date) == (before ? "2026-10-02 23:59:59 UTC" : "2026-10-03 00:00:00 UTC")
                }
            }
            for await matches in group { XCTAssertTrue(matches) }
        }
    }
}
