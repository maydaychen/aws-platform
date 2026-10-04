import Foundation
import XCTest
@testable import AWSPlatform

final class LocalizationTests: XCTestCase {
    private let en = Locale(identifier: "en")
    private let zh = Locale(identifier: "zh-Hans")

    func testSystemLanguageUsesSupportedPreferredLanguageAndFallsBackToEnglish() {
        XCTAssertEqual(AppLanguage.system.locale(preferredLanguages: ["zh-Hans-CN", "en"]).language.languageCode?.identifier, "zh")
        XCTAssertEqual(AppLanguage.system.locale(preferredLanguages: ["en-GB", "zh-Hans"]).language.languageCode?.identifier, "en")
        XCTAssertEqual(AppLanguage.system.locale(preferredLanguages: ["fr-FR"]).language.languageCode?.identifier, "en")
    }

    func testExplicitLanguageOverridesSystemPreference() {
        XCTAssertEqual(AppLanguage.english.locale(preferredLanguages: ["zh-Hans"]).language.languageCode?.identifier, "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.locale(preferredLanguages: ["en"]).language.languageCode?.identifier, "zh")
    }

    @MainActor
    func testSelectionPersistsAndCanReturnToFollowingSystem() throws {
        let name = "AWSPlatformTests.Localization.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let inheritedLanguages = defaults.stringArray(forKey: "AppleLanguages")
        let standardLanguages = UserDefaults.standard.stringArray(forKey: "AppleLanguages")
        let settings = LanguageSettings(defaults: defaults, preferredLanguages: ["en"])
        XCTAssertEqual(settings.selection, .system)
        settings.selection = .simplifiedChinese
        XCTAssertEqual(settings.locale.language.languageCode?.identifier, "zh")
        let restored = LanguageSettings(defaults: defaults, preferredLanguages: ["en"])
        XCTAssertEqual(restored.selection, .simplifiedChinese)
        restored.selection = .system
        XCTAssertEqual(restored.locale.language.languageCode?.identifier, "en")
        XCTAssertNil(defaults.persistentDomain(forName: name)?["AppleLanguages"], "Do not write a Cocoa language override into the app preference domain")
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), inheritedLanguages, "Do not change inherited Cocoa language preferences")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "AppleLanguages"), standardLanguages, "Do not change standard Cocoa language preferences")
    }

    @MainActor
    func testInvalidPreferenceFallsBackWithoutChangingProfileOrService() throws {
        let name = "AWSPlatformTests.Localization.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("unsupported", forKey: LanguageSettings.defaultsKey)
        defaults.set("test-profile", forKey: "selectedProfile")
        defaults.set(AWSService.ec2.rawValue, forKey: "selectedService")
        let settings = LanguageSettings(defaults: defaults, preferredLanguages: ["en"])
        XCTAssertEqual(settings.selection, .system)
        settings.selection = .simplifiedChinese
        XCTAssertEqual(defaults.string(forKey: "selectedProfile"), "test-profile")
        XCTAssertEqual(defaults.string(forKey: "selectedService"), AWSService.ec2.rawValue)
    }

    func testExistingAppMessageCanBeRenderedInEitherLanguageWithoutMutation() {
        let storedMessage = "Loading cancelled. Use Refresh to try again."
        let english = L10n.text(storedMessage, locale: en)
        let chinese = L10n.text(storedMessage, locale: zh)
        XCTAssertEqual(english, storedMessage)
        XCTAssertNotEqual(chinese, storedMessage)
        XCTAssertFalse(chinese.isEmpty)
        XCTAssertEqual(L10n.text(storedMessage, locale: en), english)
    }

    func testEmptyUnknownAndExternalErrorTextRemainIntact() {
        for value in ["", "External error code WIDGET_123: cannot find example", "arn:aws:lambda:us-east-1:123456789012:function:Refresh", "my-resource-name", "line one\nline two"] {
            XCTAssertEqual(L10n.text(value, locale: zh), value)
        }
    }

    func testEnglishAndChineseCountsIncludingZeroAndMultiple() {
        XCTAssertEqual(L10n.format("%@ resource", "1", locale: en), "1 resource")
        XCTAssertEqual(L10n.format("%@ resources", "0", locale: zh), "0 个资源")
        XCTAssertEqual(L10n.format("%@ of %@ resources", "2", "15", locale: zh), "显示 2／15 个资源")
    }

    func testExplicitParametersKeepNamesAndPercentTokensVerbatim() {
        let resource = "Name %@ %2$@ : in account 100% 🔒"
        let translated = L10n.format("Open %@ in account %@, profile %@, region %@", resource, "123456789012", "All", "us-east-1", locale: zh)
        XCTAssertEqual(translated, "打开 \(resource)，账号 123456789012，Profile All，区域 us-east-1")
    }

    func testExplicitParametersCanBeReorderedWithoutTranslatingProfileName() {
        let translated = L10n.format("Remove recent history for profile %@ in account %@? AWS resources and favorites will remain unchanged.", "Refresh", "123456789012", locale: zh)
        XCTAssertTrue(translated.contains("账号 123456789012 中 Profile Refresh"))
        XCTAssertFalse(translated.contains("Profile 刷新"))
    }

    func testExplicitMultilineParametersRemainVerbatim() {
        let resource = "Name %@ %2$@ 100%\nLoading cancelled. Use Refresh to try again."
        let translated = L10n.format("Open %@ in account %@, profile %@, region %@", resource, "123456789012", "All", "us-east-1", locale: zh)
        XCTAssertEqual(translated, "打开 \(resource)，账号 123456789012，Profile All，区域 us-east-1")
    }

    func testHealthStatusLabelsAcceptUppercaseEntityStatesWithoutChangingUnknownValues() {
        for (value, english, chinese) in [("PENDING", "Pending", "待处理"), ("IMPAIRED", "Impaired", "受损"),
                                          ("RESOLVED", "Resolved", "已解决"), ("UNIMPAIRED", "Unimpaired", "未受影响"),
                                          ("All", "All", "全部"), ("scheduledChange", "Scheduled change", "计划变更"),
                                          ("accountNotification", "Account notification", "账号通知")] {
            XCTAssertEqual(HealthDisplay.label(value, locale: en), english)
            XCTAssertEqual(HealthDisplay.label(value, locale: zh), chinese)
        }
        XCTAssertEqual(HealthDisplay.label("RAW_UNKNOWN_STATE", locale: zh), "RAW_UNKNOWN_STATE")
    }

    func testLegacySingleArgumentProfileMessagePreservesName() {
        let name = "All %@ : profile \"开发\""
        let stored = "AWS connection validation failed for `\(name)`. Check your network, region and credentials, then retry."
        let translated = L10n.text(stored, locale: zh)
        XCTAssertNotEqual(translated, stored)
        XCTAssertTrue(translated.contains(name))
    }

    func testAmbiguousLegacyArgumentsStayIntact() {
        let stored = "Open resource in account embedded in account 123456789012, profile All, region us-east-1"
        XCTAssertEqual(L10n.text(stored, locale: zh), stored)
    }

    func testNestedStoredErrorsAndMultilineWarningsUpdateTogether() {
        let error = "Loading cancelled. Use Refresh to try again."
        let stored = "Could not update the report. Showing the saved result below. \(error)"
        let translated = L10n.text(stored, locale: zh)
        XCTAssertNotEqual(translated, stored)
        XCTAssertFalse(translated.contains(error))
        let lines = L10n.text("Tags: \(error)\nEncryption: \(error)", locale: zh)
        XCTAssertEqual(lines, "标签：加载已取消。请点击刷新重试。\n加密：加载已取消。请点击刷新重试。")
    }

    func testCatalogsHaveMatchingKeysAndSafePlaceholders() throws {
        let english = try catalog(language: "en")
        let chinese = try catalog(language: "zh-Hans")
        XCTAssertGreaterThan(english.count, 800)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        let tokenPattern = try NSRegularExpression(pattern: #"%(?:[0-9]+\$)?@"#)
        for (key, value) in chinese {
            let count = tokenPattern.numberOfMatches(in: key, range: NSRange(key.startIndex..., in: key))
            let translatedCount = tokenPattern.numberOfMatches(in: value, range: NSRange(value.startIndex..., in: value))
            XCTAssertEqual(count, translatedCount, key)
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertEqual(english[key], key)
        }
    }

    func testEveryCatalogTemplateCanRenderAndPreserveArguments() throws {
        let english = try catalog(language: "en")
        for key in english.keys where key.contains("%@") {
            // Legacy two-or-more argument templates may intentionally reject ambiguous delimiters.
            let count = key.components(separatedBy: "%@").count - 1
            guard count == 1 else { continue }
            let value = "RESOURCE-42-%@-原文"
            let source = key.replacingOccurrences(of: "%@", with: value)
            let translated = L10n.text(source, locale: zh)
            XCTAssertTrue(translated.contains(value), key)
            XCTAssertNotEqual(translated, source, key)
        }
    }

    private func catalog(language: String) throws -> [String: String] {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: language, withExtension: "lproj"))
        let data = try Data(contentsOf: directory.appendingPathComponent("Localizable.strings"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
}
