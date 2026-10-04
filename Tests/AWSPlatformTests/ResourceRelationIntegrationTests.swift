import XCTest
@testable import AWSPlatform

@MainActor
final class ResourceRelationIntegrationTests: XCTestCase {
    private let profile = AWSProfile(name: "relations", region: "us-east-1", ssoStartURL: nil,
                                     ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
    private let identity = AWSIdentity(account: "111122223333", arn: "arn:aws:iam::111122223333:user/test", userID: "test")
    private let paths = AWSConfigurationPaths(environment: [
        "AWS_CONFIG_FILE": "/example/relations/config", "AWS_SHARED_CREDENTIALS_FILE": "/example/relations/credentials"
    ])

    private func scope(_ region: String = "us-east-1") -> MonitoringScope {
        MonitoringScope(profile: profile, identity: identity, region: region, paths: paths)
    }

    func testExplicitRegionalRelationshipClientsReuseIdentityWithoutChangingWorkspaceRegion() async throws {
        let provider = AWSServiceProvider()
        await provider.configure(profile: profile, region: "us-east-1", paths: paths)
        let workspace = try await provider.elbClient(scope: scope())
        let foreignRegion = scope("eu-west-1")
        let relation = try await provider.relationshipELBClient(scope: foreignRegion)
        let ec2 = try await provider.relationshipEC2Client(scope: foreignRegion)
        XCTAssertEqual(relation.config.region.rawValue, "eu-west-1")
        XCTAssertEqual(ec2.config.region.rawValue, "eu-west-1")
        XCTAssertTrue(workspace.client === relation.client)
        XCTAssertTrue(workspace.client === ec2.client)
        let current = await provider.currentRegion
        XCTAssertEqual(current, "us-east-1")
        _ = try await provider.elbClient(scope: scope())
        do {
            _ = try await provider.elbClient(scope: foreignRegion)
            XCTFail("The ordinary ELB factory must still reject a different workspace region")
        } catch { XCTAssertEqual(error as? ELBError, .invalidScope) }
        await provider.shutdown()
    }

    func testRelationshipClientsRejectDifferentProfilePathsPartitionAndClearedIdentity() async {
        let provider = AWSServiceProvider()
        await provider.configure(profile: profile, region: "us-east-1", paths: paths)
        let other = AWSProfile(name: "other", region: "us-east-1", ssoStartURL: nil,
                               ssoRegion: nil, ssoAccountID: nil, ssoRoleName: nil)
        let invalid = [
            MonitoringScope(profile: other, identity: identity, region: "us-east-1", paths: paths),
            MonitoringScope(profile: profile, identity: identity, region: "us-east-1",
                            paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": "/different/config", "AWS_SHARED_CREDENTIALS_FILE": paths.credentials])),
            scope("cn-north-1"), scope("global"), scope("eu-west-1\n")
        ]
        for value in invalid { await assertRejected(provider, scope: value) }
        await provider.configure(profile: nil, region: "us-east-1", paths: paths)
        await assertRejected(provider, scope: scope())
    }

    func testRecordIdentityIncludesZoneAndRoutingIdentifierAndQueryRegionIsContextOnly() {
        let record = Route53Record.ID(name: "api.example.test.", type: "A", setIdentifier: "blue")
        let first = ResourceRelationReference(scope: scope(), service: .route53, resourceID: "ZONE1", name: record.name, recordID: record)
        let otherZone = ResourceRelationReference(scope: scope(), service: .route53, resourceID: "ZONE2", name: record.name, recordID: record)
        let otherSet = ResourceRelationReference(scope: scope(), service: .route53, resourceID: "ZONE1", name: record.name,
                                                recordID: .init(name: record.name, type: "A", setIdentifier: "green"))
        XCTAssertTrue(first.isValid)
        XCTAssertNotEqual(first, otherZone)
        XCTAssertNotEqual(first, otherSet)
        let next = first.replacingRegion("eu-west-1")
        XCTAssertTrue(next.isValid)
        XCTAssertEqual(next.recordID, record)
        XCTAssertEqual(next.scope.route53Scope, first.scope.route53Scope)
        XCTAssertTrue(next.scope.sharesIdentity(with: first.scope))
        XCTAssertEqual(next.favoriteDestination.region, "global")
        XCTAssertEqual(next.favoriteDestination.resourceID, "ZONE1")
    }

    func testReferencesRejectMalformedGroupsUnsupportedServicesAndCrossAccountARNs() {
        for id in ["sg-not-an-id", "sg-12345678\n", "SG-12345678", "sg-0123456789abcdef00"] {
            XCTAssertFalse(ResourceRelationReference(scope: scope(), service: .securityGroups, resourceID: id, name: "group").isValid)
        }
        XCTAssertTrue(ResourceRelationReference(scope: scope(), service: .securityGroups, resourceID: "sg-12345678", name: "group").isValid)
        XCTAssertFalse(ResourceRelationReference(scope: scope(), service: .s3, resourceID: "bucket", name: "bucket").isValid)
        XCTAssertFalse(ResourceRelationReference(scope: scope(), service: .loadBalancers,
            resourceID: "arn:aws:elasticloadbalancing:us-east-1:444455556666:loadbalancer/app/api/123", name: "api").isValid)
    }

    func testQualifiedLambdaReferencePreservesARNButTransientDestinationUsesBaseName() {
        let arn = "arn:aws:lambda:us-east-1:111122223333:function:handler:live"
        let reference = ResourceRelationReference(scope: scope(), service: .lambda, resourceID: arn, name: "handler:live")
        XCTAssertTrue(reference.isValid)
        XCTAssertFalse(reference.canExplore)
        XCTAssertEqual(reference.resourceID, arn)
        XCTAssertEqual(reference.favoriteDestination.resourceID, "handler")
        XCTAssertEqual(reference.favoriteDestination.region, "us-east-1")
    }

    private func assertRejected(_ provider: AWSServiceProvider, scope: MonitoringScope) async {
        do { _ = try await provider.relationshipELBClient(scope: scope); XCTFail("Invalid relationship ELB scope accepted") }
        catch { XCTAssertEqual(error as? ELBError, .invalidScope) }
        do { _ = try await provider.relationshipEC2Client(scope: scope); XCTFail("Invalid relationship EC2 scope accepted") }
        catch { XCTAssertEqual(error as? SecurityGroupError, .invalidScope) }
    }
}
