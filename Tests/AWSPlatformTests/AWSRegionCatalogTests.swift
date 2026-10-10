import XCTest
@testable import AWSPlatform

final class AWSRegionCatalogTests: XCTestCase {
    func testLocationsAreLocalizedWithoutChangingRegionCodes() {
        XCTAssertEqual(AWSRegionCatalog.displayName(for: "ap-southeast-1", locale: Locale(identifier: "en")),
                       "Singapore · ap-southeast-1")
        XCTAssertEqual(AWSRegionCatalog.displayName(for: "ap-southeast-1", locale: Locale(identifier: "zh-Hans")),
                       "新加坡 · ap-southeast-1")
        XCTAssertEqual(AWSRegionCatalog.displayName(for: "eu-future-1", locale: Locale(identifier: "zh-Hans")),
                       "eu-future-1")
        for (code, name) in AWSRegionCatalog.locations {
            XCTAssertFalse(name.isEmpty)
            XCTAssertTrue(AWSRegionCatalog.displayName(for: code, locale: Locale(identifier: "en")).hasSuffix(" · " + code))
        }
    }
}
