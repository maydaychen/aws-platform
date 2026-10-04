import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    func locale(preferredLanguages: [String] = Locale.preferredLanguages) -> Locale {
        let identifier = self == .system
            ? Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: preferredLanguages).first ?? "en"
            : rawValue
        return Locale(identifier: identifier)
    }
}

@MainActor
final class LanguageSettings: ObservableObject {
    static let defaultsKey = "appLanguage"
    private let defaults: UserDefaults
    @Published var selection: AppLanguage {
        didSet { defaults.set(selection.rawValue, forKey: Self.defaultsKey) }
    }
    @Published private(set) var systemLanguages: [String]

    init(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.defaults = defaults
        selection = AppLanguage(rawValue: defaults.string(forKey: Self.defaultsKey) ?? "") ?? .system
        systemLanguages = preferredLanguages
    }

    var locale: Locale { selection.locale(preferredLanguages: systemLanguages) }

    func refreshSystemLanguages() {
        let current = Locale.preferredLanguages
        if systemLanguages != current { systemLanguages = current }
    }
}

/// Resolves app-owned display text at the view boundary. Domain strings, identifiers,
/// tags, AWS response bodies and persisted values must never be passed through here.
/// Existing async models retain English messages so changing language does not reload data.
enum L10n {
    private struct MessageTemplate: Sendable {
        let key: String
        let parts: [String]
        let nestedMessages: Set<Int>

        func arguments(in source: String) -> [String]? {
            // Separate warnings must not become arguments of a longer single-line template.
            // Explicit format arguments bypass this legacy parser and remain opaque.
            guard !source.contains("\n") || key.contains("\n") else { return nil }
            guard parts.count > 1, source.hasPrefix(parts[0]), source.hasSuffix(parts[parts.count - 1]) else { return nil }
            var position = source.index(source.startIndex, offsetBy: parts[0].count)
            var result: [String] = []
            for index in 1..<parts.count {
                let delimiter = parts[index]
                if index == parts.count - 1 {
                    let end = source.index(source.endIndex, offsetBy: -delimiter.count)
                    guard position <= end else { return nil }
                    result.append(String(source[position..<end]))
                    position = source.endIndex
                } else {
                    guard !delimiter.isEmpty, let range = source.range(of: delimiter, range: position..<source.endIndex) else { return nil }
                    // Legacy String messages cannot distinguish a delimiter inside a name
                    // from a structural delimiter. Keep ambiguous content intact.
                    guard source.range(of: delimiter, range: range.upperBound..<source.endIndex) == nil else { return nil }
                    result.append(String(source[position..<range.lowerBound]))
                    position = range.upperBound
                }
            }
            return position == source.endIndex ? result : nil
        }
    }

    private static let english = localizedBundle("en")
    private static let chinese = localizedBundle("zh-Hans")
    private static let templates: [MessageTemplate] = {
        guard let url = english.url(forResource: "Localizable", withExtension: "strings"),
              let data = try? Data(contentsOf: url),
              let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [] }
        let nested: [String: [Int]] = {
            guard let url = Bundle.module.url(forResource: "MessageArguments", withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let values = try? JSONDecoder().decode([String: [Int]].self, from: data) else { return [:] }
            return values
        }()
        return entries.keys.filter { $0.contains("%@") }.map {
            MessageTemplate(key: $0, parts: $0.components(separatedBy: "%@"), nestedMessages: Set(nested[$0] ?? []))
        }.sorted {
            // Prefer specific sentences over shorter prefixes; ordering stays deterministic.
            let left = $0.parts.joined().count
            let right = $1.parts.joined().count
            return left == right ? $0.key < $1.key : left > right
        }
    }()

    static func text(_ source: String, locale: Locale) -> String {
        resolve(source, locale: locale, depth: 0)
    }

    static func format(_ key: String, _ arguments: String..., locale: Locale) -> String {
        render(bundle(for: locale).localizedString(forKey: key, value: key, table: nil), arguments: arguments)
    }

    private static func resolve(_ source: String, locale: Locale, depth: Int) -> String {
        guard locale.language.languageCode?.identifier == "zh", !source.isEmpty, depth < 8 else { return source }
        let translated = chinese.localizedString(forKey: source, value: source, table: nil)
        if translated != source { return translated }
        for template in templates {
            guard var arguments = template.arguments(in: source) else { continue }
            let pattern = chinese.localizedString(forKey: template.key, value: template.key, table: nil)
            for index in template.nestedMessages where arguments.indices.contains(index) {
                arguments[index] = resolve(arguments[index], locale: locale, depth: depth + 1)
            }
            return render(pattern, arguments: arguments)
        }
        if source.contains("\n") {
            return source.components(separatedBy: "\n").map { resolve($0, locale: locale, depth: depth + 1) }.joined(separator: "\n")
        }
        return source
    }

    /// Substitution never interprets percent signs or placeholders in resource names/arguments.
    private static func render(_ pattern: String, arguments: [String]) -> String {
        var result = ""
        var position = pattern.startIndex
        var sequential = 0
        while position < pattern.endIndex {
            let remainder = pattern[position...]
            if remainder.hasPrefix("%@") {
                guard arguments.indices.contains(sequential) else { return pattern }
                result += arguments[sequential]
                sequential += 1
                position = pattern.index(position, offsetBy: 2)
                continue
            }
            if pattern[position] == "%", let at = remainder.firstIndex(of: "@") {
                let token = String(pattern[pattern.index(after: position)..<at])
                if token.hasSuffix("$"), let number = Int(token.dropLast()), arguments.indices.contains(number - 1) {
                    result += arguments[number - 1]
                    position = pattern.index(after: at)
                    continue
                }
            }
            result.append(pattern[position])
            position = pattern.index(after: position)
        }
        return result
    }

    private static func bundle(for locale: Locale) -> Bundle {
        locale.language.languageCode?.identifier == "zh" ? chinese : english
    }

    private static func localizedBundle(_ language: String) -> Bundle {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) else {
            return Bundle.module
        }
        return bundle
    }
}
