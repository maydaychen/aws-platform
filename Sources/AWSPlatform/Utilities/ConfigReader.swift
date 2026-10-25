import Foundation
import Darwin

enum AWSConfigurationReadError: String, LocalizedError {
    case notDownloaded = "AWS configuration files are stored in the cloud. Download them in Finder, then reload profiles."
    case notRegularFile = "AWS configuration paths must point to regular files. Check both paths, then reload profiles."
    case unavailable = "AWS configuration could not be loaded. Check the local configuration files, then reload profiles."

    var errorDescription: String? { rawValue }
}

struct ConfigReader {
    typealias MetadataReader = (String) throws -> stat?

    static func readSessions(
        paths: AWSConfigurationPaths = AWSConfigurationPaths(),
        metadataReader: MetadataReader = fileMetadata
    ) throws -> [AWSSOSession] {
        let config = try readText(paths.config, metadataReader: metadataReader)
        return readSessions(configContent: config)
    }

    static func readSessions(configContent content: String) -> [AWSSOSession] {
        var seenNames: Set<String> = []
        return parseINI(content: content).compactMap { section in
            let sectionName = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sectionName.hasPrefix("sso-session ") else { return nil }
            let name = String(sectionName.dropFirst("sso-session ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seenNames.insert(name).inserted else { return nil }
            return AWSSOSession(name: name)
        }
    }

    static func readProfiles(
        paths: AWSConfigurationPaths = AWSConfigurationPaths(),
        metadataReader: MetadataReader = fileMetadata
    ) throws -> [AWSProfile] {
        let config = try readText(paths.config, metadataReader: metadataReader)
        let credentials = try readText(paths.credentials, metadataReader: metadataReader)
        return readProfiles(configContent: config, credentialsContent: credentials)
    }

    private static func fileMetadata(_ path: String) -> stat? {
        var info = stat()
        // stat follows existing symlink configurations without opening cloud placeholders.
        return stat(path, &info) == 0 ? info : nil
    }

    private static func validate(_ info: stat) throws {
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else { throw AWSConfigurationReadError.notDownloaded }
        guard info.st_mode & S_IFMT == S_IFREG else { throw AWSConfigurationReadError.notRegularFile }
    }

    private static func readText(_ path: String, metadataReader: MetadataReader) throws -> String {
        guard let expected = try metadataReader(path) else { return "" }
        try validate(expected)
        // A regular path may be replaced with a FIFO after stat. Nonblocking open
        // and the descriptor check ensure such a replacement cannot stall startup.
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return "" }
        defer { close(descriptor) }
        var actual = stat()
        guard fstat(descriptor, &actual) == 0 else { return "" }
        try validate(actual)
        guard actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino else { return "" }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.readToEnd() else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
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
            ssoRoleName: values["sso_role_name"],
            ssoSessionName: values["sso_session"].flatMap { $0.isEmpty ? nil : $0 },
            roleARN: values["role_arn"].flatMap { $0.isEmpty ? nil : $0 },
            sourceProfile: values["source_profile"].flatMap { $0.isEmpty ? nil : $0 }
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
