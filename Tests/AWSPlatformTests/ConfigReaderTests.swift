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

        XCTAssertEqual(ConfigReader.readSessions(paths: paths).map(\.name), ["configured"])
        try FileManager.default.removeItem(at: config)
        XCTAssertTrue(ConfigReader.readSessions(paths: paths).isEmpty)
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
        let profiles = ConfigReader.readProfiles(paths: paths)
        XCTAssertEqual(profiles.map(\.name), ["configured", "credentials-only"])
        XCTAssertEqual(profiles.first?.region, "ap-east-1")
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
}
