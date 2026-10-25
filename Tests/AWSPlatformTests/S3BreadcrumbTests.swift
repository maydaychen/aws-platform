import XCTest
@testable import AWSPlatform

final class S3BreadcrumbTests: XCTestCase {
    func testRootAndNestedAncestorsAreExact() {
        XCTAssertEqual(S3Breadcrumb.path(for: ""), [.init(name: "", prefix: "")])
        let path = S3Breadcrumb.path(for: "a/b/c/")
        XCTAssertEqual(path.map(\.name), ["", "a", "b", "c"])
        XCTAssertEqual(path.map(\.prefix), ["", "a/", "a/b/", "a/b/c/"])
    }

    func testRepeatedAndLeadingSlashesAndDotSegmentsAreNotNormalized() {
        let path = S3Breadcrumb.path(for: "/a//./../")
        XCTAssertEqual(path.map(\.prefix), ["", "/", "/a/", "/a//", "/a//./", "/a//./../"])
        XCTAssertEqual(path.map(\.name), ["", "", "a", "", ".", ".."])
        XCTAssertEqual(Set(path.map(\.id)).count, path.count)
    }

    func testUnicodeSpacesPercentAndNonTrailingPrefixStayLiteral() {
        let path = S3Breadcrumb.path(for: "中文 👶/a%2Fb + #/尾部")
        XCTAssertEqual(path.map(\.prefix), ["", "中文 👶/", "中文 👶/a%2Fb + #/", "中文 👶/a%2Fb + #/尾部"])
        XCTAssertEqual(path.last?.name, "尾部")
        XCTAssertEqual(S3Breadcrumb.path(for: "a/\u{301}b/").map(\.prefix), ["", "a/", "a/\u{301}b/"])
    }

    func testNewDirectoryAndPaginationMessagesRenderInBothLanguages() {
        let en = Locale(identifier: "en")
        let zh = Locale(identifier: "zh-Hans")
        let messages = ["Search loaded objects", "More items available. Search filters loaded items only.",
                        "All items loaded. Search filters this directory only.", "Search filters loaded items only.",
                        "No matching objects in the pages loaded so far. Use Load more to continue.",
                        S3PaginationError.invalidContinuation.errorDescription!]
        for message in messages {
            XCTAssertEqual(L10n.text(message, locale: en), message)
            XCTAssertNotEqual(L10n.text(message, locale: zh), message)
        }
        XCTAssertEqual(L10n.format("%@ loaded items", "10", locale: zh), "已加载 10 项")
        XCTAssertEqual(L10n.format("%@ of %@ loaded items", "2", "10", locale: zh), "显示 2／10 个已加载项")
        XCTAssertEqual(L10n.format("Directory %@", "s3://example/中文//", locale: zh), "目录 s3://example/中文//")
    }

    func testByteDistinctUnicodePrefixesHaveSeparateIdentity() {
        let composed = S3Breadcrumb.path(for: "caf\u{e9}/").last!
        let decomposed = S3Breadcrumb.path(for: "cafe\u{301}/").last!
        XCTAssertNotEqual(composed.id, decomposed.id)
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertEqual(Data(decomposed.prefix.utf8), Data("cafe\u{301}/".utf8))
    }
}
