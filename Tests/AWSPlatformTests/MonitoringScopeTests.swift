import XCTest
@testable import AWSPlatform

final class MonitoringScopeTests: XCTestCase {
    func testScopeRequiresConsistentVerifiedIdentityAndPartition() {
        XCTAssertTrue(scope().isValid)
        XCTAssertFalse(scope(profile: " ").isValid)
        XCTAssertFalse(scope(account: "invalid").isValid)
        XCTAssertFalse(scope(principal: "arn:aws:iam::222222222222:user/test").isValid)
        XCTAssertFalse(scope(principal: "arn:aws:lambda:us-east-1:111111111111:function:test").isValid)
        XCTAssertFalse(scope(region: "cn-north-1").isValid)
        XCTAssertFalse(scope(region: "invalid").isValid)
        XCTAssertFalse(scope(region: "us-east-1\n").isValid)
        XCTAssertFalse(scope(account: "111111111111\n").isValid)
        XCTAssertTrue(scope(region: "cn-north-1", principal: "arn:aws-cn:sts::111111111111:assumed-role/ReadOnly/test").isValid)
    }

    func testConfigurationPathsAndPrincipalParticipateInScopeIdentity() {
        let original = scope()
        let changedPath = MonitoringScope(
            profile: original.profile,
            identity: AWSIdentity(account: original.accountID, arn: original.principalARN, userID: "test"),
            region: original.region,
            paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/tmp/monitoring-test-config"])
        )
        XCTAssertNotEqual(original, changedPath)
        XCTAssertEqual(changedPath.paths.config, "/tmp/monitoring-test-config")
        XCTAssertNotEqual(original, scope(principal: "arn:aws:iam::111111111111:role/ReadOnly"))
        XCTAssertEqual(Set([original, changedPath]).count, 2)
    }

    private func scope(profile: String = "work", account: String = "111111111111", region: String = "us-east-1",
                       principal: String = "arn:aws:iam::111111111111:user/test") -> MonitoringScope {
        MonitoringScope(profile: AWSProfile(name: profile, region: region, ssoStartURL: nil, ssoRegion: nil,
                                            ssoAccountID: nil, ssoRoleName: nil),
                        identity: AWSIdentity(account: account, arn: principal, userID: "test"), region: region)
    }
}
