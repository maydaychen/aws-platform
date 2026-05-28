import Foundation

struct ConfigReader {
    static func readProfiles() -> [AWSProfile] {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/config")

        guard let content = try? String(contentsOf: configPath, encoding: .utf8) else {
            return []
        }

        let sections = parseINI(content: content)
        return sections.compactMap { section in
            let normalized = normalizeSectionName(section.name)
            guard !normalized.isEmpty, normalized != "default" || !section.values.isEmpty else {
                return normalized.isEmpty ? nil : makeProfile(name: normalized, values: section.values)
            }
            return makeProfile(name: normalized, values: section.values)
        }
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

    private static func normalizeSectionName(_ section: String) -> String {
        let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "default" { return "default" }
        if trimmed.hasPrefix("profile ") {
            return String(trimmed.dropFirst("profile ".count))
        }
        return trimmed
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
