import XCTest
@testable import AWSPlatform

final class ConfigReaderTests: XCTestCase {
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
