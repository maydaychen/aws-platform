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
    typealias Configuration = (profiles: [AWSProfile], sessions: [AWSSOSession])

    static func readConfiguration(
        paths: AWSConfigurationPaths = AWSConfigurationPaths(),
        metadataReader: MetadataReader = fileMetadata,
        readContents: (FileHandle) throws -> Data? = { try $0.readToEnd() }
    ) throws -> Configuration {
        let config = try readText(paths.config, metadataReader: metadataReader, readContents: readContents)
        let credentials = try readText(paths.credentials, metadataReader: metadataReader, readContents: readContents)
        let sections = parseINI(content: config)
        return (profiles(in: sections, credentialsContent: credentials), sessions(in: sections))
    }

    static func readSessions(
        paths: AWSConfigurationPaths = AWSConfigurationPaths(),
        metadataReader: MetadataReader = fileMetadata
    ) throws -> [AWSSOSession] {
        let config = try readText(paths.config, metadataReader: metadataReader)
        return readSessions(configContent: config)
    }

    static func readSessions(configContent content: String) -> [AWSSOSession] {
        sessions(in: parseINI(content: content))
    }

    private static func sessions(in sections: [(name: String, values: [String: String])]) -> [AWSSOSession] {
        var seenNames: Set<String> = []
        return sections.compactMap { section in
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
        try readConfiguration(paths: paths, metadataReader: metadataReader).profiles
    }

    private static func fileMetadata(_ path: String) throws -> stat? {
        var info = stat()
        // stat follows existing symlink configurations without opening cloud placeholders.
        if stat(path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw AWSConfigurationReadError.unavailable
    }

    private static func validate(_ info: stat) throws {
        guard info.st_flags & UInt32(SF_DATALESS) == 0 else { throw AWSConfigurationReadError.notDownloaded }
        guard info.st_mode & S_IFMT == S_IFREG else { throw AWSConfigurationReadError.notRegularFile }
    }

    private static func readText(_ path: String, metadataReader: MetadataReader,
                                 readContents: (FileHandle) throws -> Data? = { try $0.readToEnd() }) throws -> String {
        guard let expected = try metadataReader(path) else { return "" }
        try validate(expected)
        // A regular path may be replaced with a FIFO after stat. Nonblocking open
        // and the descriptor check ensure such a replacement cannot stall startup.
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        // Metadata already identified a file. Its disappearance here is a failed read.
        guard descriptor >= 0 else { throw AWSConfigurationReadError.unavailable }
        defer { close(descriptor) }
        var actual = stat()
        guard fstat(descriptor, &actual) == 0 else { throw AWSConfigurationReadError.unavailable }
        try validate(actual)
        guard actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino else {
            throw AWSConfigurationReadError.unavailable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data: Data
        do { data = try readContents(handle) ?? Data() }
        catch { throw AWSConfigurationReadError.unavailable }
        guard let text = String(data: data, encoding: .utf8) else { throw AWSConfigurationReadError.unavailable }
        return text
    }

    static func readProfiles(configContent content: String, credentialsContent: String = "") -> [AWSProfile] {
        profiles(in: parseINI(content: content), credentialsContent: credentialsContent)
    }

    private static func profiles(in sections: [(name: String, values: [String: String])],
                                 credentialsContent: String) -> [AWSProfile] {
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
            guard let value = environment[variable], !value.isEmpty else {
                return homeDirectory.appendingPathComponent(fallback).path
            }
            if value == "~" { return homeDirectory.path }
            if value.hasPrefix("~/") {
                return homeDirectory.path + "/" + value.dropFirst(2)
            }
            if value.hasPrefix("/") { return value }
            return FileManager.default.currentDirectoryPath + "/" + value
        }
        config = resolve("AWS_CONFIG_FILE", fallback: ".aws/config")
        credentials = resolve("AWS_SHARED_CREDENTIALS_FILE", fallback: ".aws/credentials")
        usesCustomConfig = config != homeDirectory.appendingPathComponent(".aws/config").path
    }
}
