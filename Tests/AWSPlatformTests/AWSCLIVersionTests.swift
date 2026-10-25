import Foundation
import XCTest
@testable import AWSPlatform

final class AWSCLIVersionTests: XCTestCase {
    func testVersionUsesNumericComparisonAndExactlyThreeNumericComponents() throws {
        let first = try XCTUnwrap(AWSCLIVersion("2.9.10"))
        let second = try XCTUnwrap(AWSCLIVersion("2.10.0"))
        XCTAssertLessThan(first, second)
        XCTAssertEqual(first.major, 2)
        XCTAssertEqual(first.minor, 9)
        XCTAssertEqual(first.patch, 10)
        XCTAssertEqual(first.description, "2.9.10")
        for invalid in ["", "2", "2.3", "2.3.4.5", "v2.3.4", "2.3.4-beta", " 2.3.4", "2.3.4\n",
                        "2..3", "2.-1.3", "２.3.4", "2.3.4;touch /tmp/no", "99999999999999999999999999.1.1"] {
            XCTAssertNil(AWSCLIVersion(invalid), invalid)
        }
    }

    func testCLIOutputParsesOnlyLeadingAWSVersionToken() {
        XCTAssertEqual(AWSCLIVersion.parseCLIOutput("aws-cli/2.38.5 Python/3.13 Darwin/25 exe/arm64"), AWSCLIVersion("2.38.5"))
        XCTAssertEqual(AWSCLIVersion.parseCLIOutput("aws-cli/1.40.0 Python/3.10"), AWSCLIVersion("1.40.0"))
        XCTAssertNil(AWSCLIVersion.parseCLIOutput("unexpected aws-cli/2.38.5"))
        XCTAssertNil(AWSCLIVersion.parseCLIOutput("aws-cli/2.38.5-custom Python/3.10"))
    }

    func testCatalogRejectsWrongMajorWrongFormulaAndNonNumericRemoteVersions() throws {
        XCTAssertEqual(try AWSCLIVersionCatalog.parseOfficial(Data("2.38.5\n".utf8)), AWSCLIVersion("2.38.5"))
        for value in ["1.40.0", "3.0.0", "2.38.5;anything", "2.38.5\n2.39.0", "https://example.com/install"] {
            XCTAssertThrowsError(try AWSCLIVersionCatalog.parseOfficial(Data(value.utf8)))
        }
        let valid = Data(#"{"name":"awscli","versions":{"stable":"2.38.5"},"url":"https://untrusted.invalid"}"#.utf8)
        XCTAssertEqual(try AWSCLIVersionCatalog.parseHomebrew(valid), AWSCLIVersion("2.38.5"))
        for value in [#"{"name":"other","versions":{"stable":"2.38.5"}}"#,
                      #"{"name":"awscli","versions":{"stable":"2.38.5_1"}}"#,
                      #"{"name":"awscli","versions":{"stable":"1.40.0"}}"#,
                      #"{"name":"awscli","versions":{}}"#] {
            XCTAssertThrowsError(try AWSCLIVersionCatalog.parseHomebrew(Data(value.utf8)))
        }
    }

    func testSourcesOnlyPermitSupportedInstallationsToUpdate() {
        XCTAssertTrue(AWSCLIInstallSource.officialPackage.supportsAutomaticUpdate)
        XCTAssertTrue(AWSCLIInstallSource.homebrew(prefix: URL(fileURLWithPath: "/opt/homebrew"),
                                                 executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew")).supportsAutomaticUpdate)
        XCTAssertFalse(AWSCLIInstallSource.unmanaged.supportsAutomaticUpdate)
    }
}
