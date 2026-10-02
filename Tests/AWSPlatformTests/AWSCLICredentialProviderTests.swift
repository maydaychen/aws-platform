import SotoCore
import XCTest
@testable import AWSPlatform

final class AWSCLICredentialProviderTests: XCTestCase {
    func testFractionalExpirationAndActionableFailureMessage() throws {
        _ = try AWSCLICredentialProvider.decode(Self.samplePayload(expiration: "2099-01-01T00:00:00.000Z"))
        let error = AWSCLICredentialProvider.ExportError.unavailable
        XCTAssertTrue(UserFacingError.loginMessage(for: error, profileName: "work").contains("AWS_CONFIG_FILE"))
        XCTAssertTrue(UserFacingError.message(for: error).contains("AWS CLI v2"))
    }

    func testCustomSSOUsesSelectedProfileAndPathsWithoutShellInterpolation() async throws {
        let paths = AWSConfigurationPaths(environment: [
            "AWS_CONFIG_FILE": "/example/custom-config",
            "AWS_SHARED_CREDENTIALS_FILE": "/example/custom-credentials"
        ])
        let provider = AWSCLICredentialProvider(profile: "work profile; echo unsafe", paths: paths) { args, env in
            XCTAssertEqual(Array(args.prefix(4)), ["configure", "export-credentials", "--profile", "work profile; echo unsafe"])
            XCTAssertEqual(env["AWS_CONFIG_FILE"], paths.config)
            XCTAssertEqual(env["AWS_SHARED_CREDENTIALS_FILE"], paths.credentials)
            XCTAssertNil(env["AWS_ACCESS_KEY_ID"])
            XCTAssertEqual(env["AWS_CLI_HISTORY_FILE"], "/dev/null")
            return Self.samplePayload()
        }
        let credential = try await provider.getCredential(logger: Logger(label: "test"))
        XCTAssertTrue(credential is RotatingCredential)
    }

    func testInvalidAndExpiredCredentialPayloadsFailWithoutEchoingOutput() {
        for payload in [Data("private-output".utf8), Self.samplePayload(expiration: "2000-01-01T00:00:00Z")] {
            XCTAssertThrowsError(try AWSCLICredentialProvider.decode(payload)) { error in
                XCTAssertFalse(error.localizedDescription.contains("private-output"))
                XCTAssertFalse(error.localizedDescription.contains("EXAMPLE"))
            }
        }
    }

    func testProcessFailureDoesNotExposeItsErrorText() async {
        let provider = AWSCLICredentialProvider(profile: "work", paths: AWSConfigurationPaths()) { _, _ in
            throw NSError(domain: "private-output", code: 1)
        }
        do {
            _ = try await provider.getCredential(logger: Logger(label: "test"))
            XCTFail("Expected an export error")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("private-output"))
        }
    }

    private static func samplePayload(expiration: String = "2099-01-01T00:00:00Z") -> Data {
        Data("""
        {"Version":1,"AccessKeyId":"EXAMPLE","SecretAccessKey":"EXAMPLE","SessionToken":"EXAMPLE","Expiration":"\(expiration)"}
        """.utf8)
    }
}
