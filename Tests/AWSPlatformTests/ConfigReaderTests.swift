import Darwin
import XCTest
@testable import AWSPlatform

final class ConfigReaderTests: XCTestCase {
    func testReadSessionsFindsIndependentSessionsWithoutProfiles() {
        let sessions = ConfigReader.readSessions(configContent: """
        [sso-session company]
        sso_start_url = https://company.example.invalid/start
        sso_region = us-east-1

        [sso-session personal]
        sso_start_url = https://personal.example.invalid/start
        sso_region = ap-southeast-1
        """)

        XCTAssertEqual(sessions.map(\.name), ["company", "personal"])
        XCTAssertEqual(sessions.map(\.id), ["company", "personal"])
    }

    func testReadSessionsDeduplicatesNamesAndIgnoresOtherOrEmptySections() {
        let sessions = ConfigReader.readSessions(configContent: """
        [default]
        [profile work]
        sso_session = missing-session
        [sso-session first]
        [services endpoints]
        [sso-session   ]
        [sso-session second]
        [sso-session first]
        [ sso-session third ]
        """)

        XCTAssertEqual(sessions.map(\.name), ["first", "second", "third"])
    }

    func testReadSessionsUsesCustomConfigWithoutReadingCredentialsSections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        let credentials = root.appendingPathComponent("credentials")
        try "[sso-session configured]".write(to: config, atomically: true, encoding: .utf8)
        try "[sso-session ignored]".write(to: credentials, atomically: true, encoding: .utf8)
        let paths = AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": config.path,
            "AWS_SHARED_CREDENTIALS_FILE": credentials.path
        ])

        XCTAssertEqual(try ConfigReader.readSessions(paths: paths).map(\.name), ["configured"])
        try FileManager.default.removeItem(at: config)
        XCTAssertTrue(try ConfigReader.readSessions(paths: paths).isEmpty)
    }

    func testProfileSessionReferenceDoesNotRequireInlineSSOFields() {
        let profiles = ConfigReader.readProfiles(configContent: """
        [profile work]
        sso_session = company
        [profile ordinary]
        sso_session =
        """)

        XCTAssertEqual(profiles[0].ssoSessionName, "company")
        XCTAssertTrue(profiles[0].isSSO)
        XCTAssertNil(profiles[1].ssoSessionName)
        XCTAssertFalse(profiles[1].isSSO)
    }

    func testMergesCredentialsOnlyProfilesWithoutDuplicatingConfigProfiles() {
        let profiles = ConfigReader.readProfiles(
            configContent: "[profile shared]\nregion = eu-central-2\n[profile shared]\noutput = json",
            credentialsContent: "[shared]\naws_access_key_id = EXAMPLE\n[credentials-only]\naws_access_key_id = EXAMPLE"
        )
        XCTAssertEqual(profiles.map(\.name), ["shared", "credentials-only"])
        XCTAssertEqual(profiles[0].region, "eu-central-2")
        XCTAssertEqual(profiles[1].region, "us-east-1")
    }

    func testCredentialsOnlyDiscoveryDoesNotRequireConfigFile() {
        let profiles = ConfigReader.readProfiles(configContent: "", credentialsContent: "[default]\n[work]")
        XCTAssertEqual(profiles.map(\.name), ["default", "work"])
    }

    func testCustomPathsExpandTildeAndIgnoreEmptyOverrides() {
        let paths = AWSConfigurationPaths(
            environment: ["AWS_CONFIG_FILE": "~/aws/custom-config", "AWS_SHARED_CREDENTIALS_FILE": " "],
            homeDirectory: URL(fileURLWithPath: "/test-home")
        )
        XCTAssertEqual(paths.config, "/test-home/aws/custom-config")
        XCTAssertEqual(paths.credentials, "/test-home/.aws/credentials")
        XCTAssertTrue(paths.usesCustomConfig)
    }

    func testReadsBothCustomFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        let credentials = root.appendingPathComponent("credentials")
        try "[profile configured]\nregion = ap-east-1".write(to: config, atomically: true, encoding: .utf8)
        try "[credentials-only]".write(to: credentials, atomically: true, encoding: .utf8)
        let paths = AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": config.path,
            "AWS_SHARED_CREDENTIALS_FILE": credentials.path
        ])
        let profiles = try ConfigReader.readProfiles(paths: paths)
        XCTAssertEqual(profiles.map(\.name), ["configured", "credentials-only"])
        XCTAssertEqual(profiles.first?.region, "ap-east-1")
    }

    func testCloudPlaceholderMetadataFailsBeforeAnyFileContentIsOpened() throws {
        let paths = AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": "/offline-placeholder/config", "AWS_SHARED_CREDENTIALS_FILE": "/offline-placeholder/credentials"
        ])
        let dataless: ConfigReader.MetadataReader = { _ in
            var info = stat()
            info.st_mode = S_IFREG | 0o600
            info.st_flags = UInt32(SF_DATALESS)
            return info
        }
        XCTAssertThrowsError(try ConfigReader.readProfiles(paths: paths, metadataReader: dataless)) {
            XCTAssertEqual($0 as? AWSConfigurationReadError, .notDownloaded)
        }
        XCTAssertThrowsError(try ConfigReader.readSessions(paths: paths, metadataReader: dataless)) {
            XCTAssertEqual($0 as? AWSConfigurationReadError, .notDownloaded)
        }
        let credentialsOnly: ConfigReader.MetadataReader = { path in
            path == paths.credentials ? try dataless(path) : nil
        }
        XCTAssertThrowsError(try ConfigReader.readProfiles(paths: paths, metadataReader: credentialsOnly)) {
            XCTAssertEqual($0 as? AWSConfigurationReadError, .notDownloaded)
        }
    }

    func testNormalSymlinkIsReadButFIFOAndDirectoryAreRejectedWithoutOpeningThem() throws {
        let root = try configurationDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        try "[profile configured]\n[sso-session company]".write(to: target, atomically: true, encoding: .utf8)
        let linked = root.appendingPathComponent("config")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        let fifo = root.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let missing = root.appendingPathComponent("missing")
        let valid = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": linked.path, "AWS_SHARED_CREDENTIALS_FILE": missing.path])
        XCTAssertEqual(try ConfigReader.readProfiles(paths: valid).map(\.name), ["configured"])
        XCTAssertEqual(try ConfigReader.readSessions(paths: valid).map(\.name), ["company"])
        for special in [fifo, root] {
            let paths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": special.path, "AWS_SHARED_CREDENTIALS_FILE": missing.path])
            XCTAssertThrowsError(try ConfigReader.readProfiles(paths: paths)) {
                XCTAssertEqual($0 as? AWSConfigurationReadError, .notRegularFile)
            }
            XCTAssertThrowsError(try ConfigReader.readSessions(paths: paths)) {
                XCTAssertEqual($0 as? AWSConfigurationReadError, .notRegularFile)
            }
        }
    }

    func testRegularFileReplacedWithFIFOBetweenMetadataAndOpenDoesNotBlock() throws {
        let root = try configurationDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config")
        try "[profile configured]".write(to: config, atomically: true, encoding: .utf8)
        let paths = AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": config.path, "AWS_SHARED_CREDENTIALS_FILE": root.appendingPathComponent("missing").path
        ])
        let metadata: ConfigReader.MetadataReader = { path in
            guard path == config.path else { return nil }
            var info = stat()
            XCTAssertEqual(stat(path, &info), 0)
            try FileManager.default.removeItem(atPath: path)
            XCTAssertEqual(mkfifo(path, 0o600), 0)
            return info
        }
        XCTAssertThrowsError(try ConfigReader.readProfiles(paths: paths, metadataReader: metadata)) {
            XCTAssertEqual($0 as? AWSConfigurationReadError, .notRegularFile)
        }
    }

    func testMissingAndInvalidUTF8FilesKeepOptionalDiscoverySemantics() throws {
        let root = try configurationDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("missing")
        let credentials = root.appendingPathComponent("credentials")
        let paths = AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": config.path, "AWS_SHARED_CREDENTIALS_FILE": credentials.path])
        try "[credentials-only]".write(to: credentials, atomically: true, encoding: .utf8)
        XCTAssertEqual(try ConfigReader.readProfiles(paths: paths).map(\.name), ["credentials-only"])
        XCTAssertTrue(try ConfigReader.readSessions(paths: paths).isEmpty)
        try Data([0xff, 0xfe]).write(to: config)
        XCTAssertEqual(try ConfigReader.readProfiles(paths: paths).map(\.name), ["credentials-only"])
        try FileManager.default.removeItem(at: credentials)
        XCTAssertTrue(try ConfigReader.readProfiles(paths: paths).isEmpty)
    }

    private func configurationDirectory() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".tmp/aws-cli-preview-install/config-reader-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testReadProfilesParsesDefaultAndNamedProfiles() {
        let profiles = ConfigReader.readProfiles(configContent: """
        [default]
        region = us-west-2

        [profile production]
        region = ap-northeast-1
        sso_start_url = https://example.awsapps.com/start
        sso_region = us-east-1
        sso_account_id = 123456789012
        sso_role_name = AdministratorAccess
        """)

        XCTAssertEqual(profiles.map(\.name), ["default", "production"])
        XCTAssertEqual(profiles[0].region, "us-west-2")
        XCTAssertEqual(profiles[1].region, "ap-northeast-1")
        XCTAssertEqual(profiles[1].displayName, "production (AdministratorAccess)")
        XCTAssertNil(profiles[1].ssoSessionName)
    }

    func testReadProfilesDefaultsMissingRegion() {
        let profiles = ConfigReader.readProfiles(configContent: """
        [profile staging]
        output = json
        """)

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].name, "staging")
        XCTAssertEqual(profiles[0].region, "us-east-1")
    }

    func testReadProfilesIgnoresCommentsAndMalformedLines() {
        let profiles = ConfigReader.readProfiles(configContent: """
        # comment
        ; another comment
        malformed

        [profile dev]
        region = eu-central-1
        output=json
        """)

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].name, "dev")
        XCTAssertEqual(profiles[0].region, "eu-central-1")
    }

    func testReadProfilesIgnoresNonProfileSections() {
        let profiles = ConfigReader.readProfiles(configContent: """
        [default]
        region = us-east-1

        [profile production]
        sso_session = company
        sso_account_id = 123456789012
        sso_role_name = ReadOnlyAccess

        [sso-session company]
        sso_start_url = https://example.awsapps.com/start
        sso_region = us-east-1

        [services custom-endpoints]
        ec2 =
          endpoint_url = https://example.invalid
        """)

        XCTAssertEqual(profiles.map(\.name), ["default", "production"])
        XCTAssertTrue(profiles[1].isSSO)
    }

    func testNamedSSOSessionKeepsProfileResourceRegionAndIdentity() {
        let profiles = ConfigReader.readProfiles(configContent: """
        [default]
        region = ap-south-1

        [profile work]
        region = ap-southeast-1
        sso_session = company
        sso_account_id = 111122223333
        sso_role_name = ReadOnlyAccess

        [sso-session company]
        sso_start_url = https://example.invalid/start
        sso_region = us-east-1
        sso_registration_scopes = sso:account:access
        """)

        XCTAssertEqual(profiles.map(\.name), ["default", "work"])
        XCTAssertFalse(profiles[0].isSSO)
        XCTAssertTrue(profiles[1].isSSO)
        XCTAssertEqual(profiles[1].region, "ap-southeast-1")
        XCTAssertEqual(profiles[1].ssoAccountID, "111122223333")
        XCTAssertEqual(profiles[1].ssoRoleName, "ReadOnlyAccess")
        XCTAssertEqual(profiles[1].displayName, "work (ReadOnlyAccess)")
        XCTAssertEqual(profiles[1].ssoSessionName, "company")
    }

    func testProfilesSharingSSOSessionKeepSeparateAccountsRolesAndRegions() {
        let profiles = ConfigReader.readProfiles(configContent: """
        [sso-session company]
        sso_start_url = https://example.invalid/start
        sso_region = us-east-1

        [profile development]
        sso_session = company
        sso_account_id = 111122223333
        sso_role_name = DeveloperAccess
        region = eu-west-1

        [profile production]
        sso_session = company
        sso_account_id = 444455556666
        sso_role_name = ReadOnlyAccess
        region = ap-southeast-1
        """)

        XCTAssertEqual(profiles.map(\.name), ["development", "production"])
        XCTAssertTrue(profiles.allSatisfy(\.isSSO))
        XCTAssertEqual(profiles.map(\.ssoAccountID), ["111122223333", "444455556666"])
        XCTAssertEqual(profiles.map(\.ssoRoleName), ["DeveloperAccess", "ReadOnlyAccess"])
        XCTAssertEqual(profiles.map(\.region), ["eu-west-1", "ap-southeast-1"])
        XCTAssertEqual(profiles.map(\.ssoSessionName), ["company", "company"])
        XCTAssertEqual(Set(profiles.map(\.id)).count, 2)
    }

    func testInterleavedSSOSessionsDoNotBecomeProfilesOrOverrideProfileMetadata() {
        let profiles = ConfigReader.readProfiles(configContent: """
        [profile first]
        sso_session = first-session
        sso_account_id = 111122223333
        sso_role_name = ReadOnlyAccess
        region = eu-central-1

        [sso-session first-session]
        sso_start_url = https://first.example.invalid/start
        sso_region = us-east-1

        [profile second]
        sso_session = second-session
        sso_account_id = 444455556666
        sso_role_name = DeveloperAccess

        [sso-session second-session]
        sso_start_url = https://second.example.invalid/start
        sso_region = ap-southeast-1
        """)

        XCTAssertEqual(profiles.map(\.name), ["first", "second"])
        XCTAssertTrue(profiles.allSatisfy(\.isSSO))
        XCTAssertEqual(profiles.map(\.ssoAccountID), ["111122223333", "444455556666"])
        XCTAssertEqual(profiles.map(\.ssoRoleName), ["ReadOnlyAccess", "DeveloperAccess"])
        XCTAssertEqual(profiles.map(\.region), ["eu-central-1", "us-east-1"])
        XCTAssertEqual(profiles.map(\.ssoSessionName), ["first-session", "second-session"])
    }

    func testReadProfilesIgnoresEmptyNamedProfile() {
        let profiles = ConfigReader.readProfiles(configContent: """
        [profile   ]
        region = us-west-2
        """)

        XCTAssertTrue(profiles.isEmpty)
    }

    func testAssumeRoleProfileParsesWithOnlySourceCredentials() throws {
        let profiles = ConfigReader.readProfiles(configContent: """
        [profile target]
        role_arn = arn:aws:iam::444455556666:role/team/ReadOnly
        source_profile = base
        region = eu-west-1
        """, credentialsContent: "[base]\naws_access_key_id = OFFLINE-EXAMPLE")
        XCTAssertEqual(profiles.map(\.name), ["target", "base"])
        let target = try XCTUnwrap(profiles.first)
        XCTAssertEqual(target.roleARN, "arn:aws:iam::444455556666:role/team/ReadOnly")
        XCTAssertEqual(target.sourceProfile, "base")
        XCTAssertEqual(target.roleAccountID, "444455556666")
        XCTAssertFalse(target.isSSO)
        XCTAssertNil(profiles.last?.roleARN)
    }

    func testRoleAndSourceChangesParticipateInProfileEquality() throws {
        func profile(role: String = "ReadOnly", source: String = "base") throws -> AWSProfile {
            try XCTUnwrap(ConfigReader.readProfiles(configContent: """
            [profile target]
            role_arn = arn:aws:iam::444455556666:role/\(role)
            source_profile = \(source)
            """).first)
        }
        let original = try profile()
        XCTAssertNotEqual(original, try profile(role: "Other"))
        XCTAssertNotEqual(original, try profile(source: "default"))
        XCTAssertEqual(original, try profile())
    }

    func testEmptyRoleMetadataPreservesOrdinaryProfiles() throws {
        let profile = try XCTUnwrap(ConfigReader.readProfiles(configContent: """
        [profile ordinary]
        role_arn =
        source_profile =
        """).first)
        XCTAssertNil(profile.roleARN)
        XCTAssertNil(profile.sourceProfile)
        XCTAssertNil(profile.roleAccountID)
        XCTAssertFalse(profile.isSSO)
    }

    func testRoleAccountOnlyAcceptsIAMRoleARNs() throws {
        for partition in ["aws", "aws-cn", "aws-us-gov"] {
            let profile = try XCTUnwrap(ConfigReader.readProfiles(configContent: """
            [profile target]
            role_arn = arn:\(partition):iam::444455556666:role/team/ReadOnly
            source_profile = default
            """).first)
            XCTAssertEqual(profile.roleAccountID, "444455556666")
        }
        for arn in [
            "arn:aws:iam::444455556666:user/name",
            "arn:aws:sts::444455556666:assumed-role/ReadOnly/session",
            "arn:aws:iam:us-east-1:444455556666:role/ReadOnly",
            "arn:aws:iam::invalid:role/ReadOnly",
            "arn:aws:iam::444455556666:role/",
            "arn:aws:iam::444455556666:role/invalid role"
        ] {
            let profile = try XCTUnwrap(ConfigReader.readProfiles(configContent: """
            [profile target]
            role_arn = \(arn)
            """).first)
            XCTAssertNil(profile.roleAccountID)
        }
    }
}
