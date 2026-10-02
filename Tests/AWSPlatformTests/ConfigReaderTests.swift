import XCTest
@testable import AWSPlatform

final class ConfigReaderTests: XCTestCase {
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

    func testReadProfilesIgnoresEmptyNamedProfile() {
        let profiles = ConfigReader.readProfiles(configContent: """
        [profile   ]
        region = us-west-2
        """)

        XCTAssertTrue(profiles.isEmpty)
    }
}
