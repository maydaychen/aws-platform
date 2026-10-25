import XCTest
@testable import AWSPlatform

final class PerformanceLocalizationTests: XCTestCase {
    func testProgressiveAndSectionMessagesHaveChineseTranslations() {
        let messages = [
            "Loading function status and tags. State filters and tag search currently use loaded summaries.",
            "No matching functions. Status and tag summaries are still loading.",
            "Loading Lambda section…",
            "Lambda section loading was cancelled.",
            "Unable to load EC2 detail section."
        ]
        for message in messages {
            XCTAssertEqual(L10n.text(message, locale: .init(identifier: "en")), message)
            let chinese = L10n.text(message, locale: .init(identifier: "zh-Hans"))
            XCTAssertNotEqual(chinese, message)
            XCTAssertFalse(chinese.isEmpty)
        }
    }
}
