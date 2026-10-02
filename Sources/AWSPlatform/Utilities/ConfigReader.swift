import Foundation

struct ConfigReader {
    static func readProfiles(
        paths: AWSConfigurationPaths = AWSConfigurationPaths()
    ) -> [AWSProfile] {
        let config = (try? String(contentsOfFile: paths.config, encoding: .utf8)) ?? ""
        let credentials = (try? String(contentsOfFile: paths.credentials, encoding: .utf8)) ?? ""
        return readProfiles(configContent: config, credentialsContent: credentials)
    }

    static func readProfiles(configContent content: String, credentialsContent: String = "") -> [AWSProfile] {
        let sections = parseINI(content: content)
        var names: [String] = []
        var valuesByName: [String: [String: String]] = [:]
        for section in sections {
            guard let name = normalizeProfileSectionName(section.name) else { continue }
            if valuesByName[name] == nil { names.append(name) }
            valuesByName[name, default: [:]].merge(section.values) { _, new in new }
        }
        // Only profile names are taken from the credentials file. Secret values
        // never become part of the observable profile model.
        for section in parseINI(content: credentialsContent) {
            let name = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, valuesByName[name] == nil else { continue }
            names.append(name)
            valuesByName[name] = [:]
        }
        return names.map { makeProfile(name: $0, values: valuesByName[$0] ?? [:]) }
    }

    private static func makeProfile(name: String, values: [String: String]) -> AWSProfile {
        AWSProfile(
            name: name,
            region: values["region"] ?? "us-east-1",
            ssoStartURL: values["sso_start_url"],
            ssoRegion: values["sso_region"],
            ssoAccountID: values["sso_account_id"],
            ssoRoleName: values["sso_role_name"]
        )
    }

    private static func normalizeProfileSectionName(_ section: String) -> String? {
        let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "default" { return "default" }
        if trimmed.hasPrefix("profile ") {
            let name = String(trimmed.dropFirst("profile ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    private static func parseINI(content: String) -> [(name: String, values: [String: String])] {
        var result: [(name: String, values: [String: String])] = []
        var currentName: String?
        var currentValues: [String: String] = [:]

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                continue
            }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                if let currentName {
                    result.append((currentName, currentValues))
                }
                currentName = String(line.dropFirst().dropLast())
                currentValues = [:]
                continue
            }

            let pieces = line.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard pieces.count == 2 else { continue }
            currentValues[pieces[0]] = pieces[1]
        }

        if let currentName {
            result.append((currentName, currentValues))
        }

        return result
    }
}

struct AWSConfigurationPaths: Equatable, Sendable {
    let config: String
    let credentials: String
    let usesCustomConfig: Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        func resolve(_ variable: String, fallback: String) -> String {
            guard let value = environment[variable],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return homeDirectory.appendingPathComponent(fallback).path
            }
            if value == "~" { return homeDirectory.path }
            if value.hasPrefix("~/") {
                return homeDirectory.appendingPathComponent(String(value.dropFirst(2))).path
            }
            return URL(fileURLWithPath: value).standardizedFileURL.path
        }
        config = resolve("AWS_CONFIG_FILE", fallback: ".aws/config")
        credentials = resolve("AWS_SHARED_CREDENTIALS_FILE", fallback: ".aws/credentials")
        usesCustomConfig = config != homeDirectory.appendingPathComponent(".aws/config").path
    }
}
