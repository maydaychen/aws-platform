import Foundation
import XCTest
import SotoEC2
import SotoAutoScaling
@testable import AWSPlatform

final class AWSAutoScalingInsightsServiceTests: XCTestCase {
    func testTemplateRequestIsExactAndDoesNotResolveSSMAlias() async throws {
        let fixture = AutoScalingInsightsFixture(templatePages: [.init(launchTemplateVersions: [asgInsightsVersion(data: .init(imageId: "resolve:ssm:/ami/web", userData: "private-script"))])])
        let rows = try await fixture.service.loadTemplateVersions(scope: asgServiceScope(), group: asgInsightsGroup(), template: asgInsightsTemplate)
        let requests = await fixture.requests()
        let request = try XCTUnwrap(requests.templates.first)
        XCTAssertEqual(request.launchTemplateId, asgInsightsTemplate.templateID)
        XCTAssertNil(request.launchTemplateName)
        XCTAssertEqual(request.versions, ["$Latest"])
        XCTAssertEqual(request.resolveAlias, false)
        XCTAssertEqual(request.maxResults, 100)
        XCTAssertNil(request.filters)
        XCTAssertEqual(rows.first?.imageID, "resolve:ssm:/ami/web")
        XCTAssertFalse(String(describing: rows).contains("private-script"))
    }

    func testNamedDefaultTemplateAndUnknownFieldsArePreserved() async throws {
        let reference = ASGLaunchTemplate(name: "web-template", version: "$Default")
        let fixture = AutoScalingInsightsFixture(templatePages: [.init(launchTemplateVersions: [asgInsightsVersion(creator: nil)])])
        let rows = try await fixture.service.loadTemplateVersions(scope: asgServiceScope(), group: asgInsightsGroup(template: reference), template: reference)
        let requests = await fixture.requests()
        XCTAssertNil(requests.templates.first?.launchTemplateId)
        XCTAssertEqual(requests.templates.first?.launchTemplateName, "web-template")
        XCTAssertEqual(requests.templates.first?.versions, ["$Default"])
        XCTAssertNil(rows.first?.isDefault)
        XCTAssertNil(rows.first?.ebsOptimized)
        XCTAssertNil(rows.first?.securityGroupIDs)
    }

    func testTemplateReferenceMustBelongToGroup() async {
        let fixture = AutoScalingInsightsFixture()
        await assertError(.invalidTemplate) {
            _ = try await fixture.service.loadTemplateVersions(scope: asgServiceScope(), group: asgInsightsGroup(template: nil), template: asgInsightsTemplate)
        }
        let requests = await fixture.requests()
        XCTAssertTrue(requests.templates.isEmpty)
    }

    func testInvalidTemplateReferencesCannotBroadenQuery() async {
        let refs = [ASGLaunchTemplate(), .init(templateID: "lt-other", version: "1"),
                    .init(name: "x", version: "1"), .init(name: "valid-name", version: nil),
                    .init(name: "valid-name", version: "0"), .init(name: "valid-name", version: "$All"),
                    .init(name: "valid-name", version: "1; echo private"), .init(name: "bad name", version: "1")]
        for reference in refs {
            let fixture = AutoScalingInsightsFixture()
            await assertError(.invalidTemplate) {
                _ = try await fixture.service.loadTemplateVersions(scope: asgServiceScope(), group: asgInsightsGroup(template: reference), template: reference)
            }
            let requests = await fixture.requests()
            XCTAssertTrue(requests.templates.isEmpty)
        }
    }

    func testNumericTemplateVersionMustMatchResponse() async {
        let reference = ASGLaunchTemplate(templateID: asgInsightsTemplate.templateID, version: "2")
        let fixture = AutoScalingInsightsFixture(templatePages: [.init(launchTemplateVersions: [asgInsightsVersion(3)])])
        await assertError(.invalidResponse) {
            _ = try await fixture.service.loadTemplateVersions(scope: asgServiceScope(), group: asgInsightsGroup(template: reference), template: reference)
        }
    }

    func testTemplateResponseIdentityOwnerAndDefaultAreValidated() async {
        let reference = ASGLaunchTemplate(templateID: asgInsightsTemplate.templateID, name: "web-template", version: "$Default")
        let invalid = [asgInsightsVersion(id: "lt-11111111111111111"), asgInsightsVersion(name: "different-template"),
                       asgInsightsVersion(creator: "arn:aws:iam::999999999999:root"),
                       asgInsightsVersion(creator: "arn:aws-cn:iam::111122223333:root"),
                       asgInsightsVersion(creator: "private-token"), asgInsightsVersion(isDefault: false), asgInsightsVersion(0)]
        for raw in invalid {
            let fixture = AutoScalingInsightsFixture(templatePages: [.init(launchTemplateVersions: [raw])])
            await assertError(.invalidResponse) {
                _ = try await fixture.service.loadTemplateVersions(scope: asgServiceScope(), group: asgInsightsGroup(template: reference), template: reference)
            }
        }
    }

    func testGroupScopeRegionAccountPartitionAndIdentifierAreValidatedBeforeRequests() async {
        let scope = asgServiceScope()
        let groups = [ASGGroup(arn: asgServiceARN().replacingOccurrences(of: "eu-west-1", with: "us-east-1"), name: "example"),
                      ASGGroup(arn: asgServiceARN().replacingOccurrences(of: "111122223333", with: "999999999999"), name: "example"),
                      ASGGroup(arn: asgServiceARN().replacingOccurrences(of: "arn:aws:", with: "arn:aws-cn:"), name: "example"),
                      ASGGroup(arn: asgServiceARN(), name: "other"),
                      ASGGroup(arn: asgServiceARN(""), name: ""),
                      ASGGroup(arn: asgServiceARN(uniqueID: ""), name: "example"),
                      ASGGroup(arn: asgServiceARN(uniqueID: " "), name: "example"),
                      ASGGroup(arn: asgServiceARN().replacingOccurrences(of: ":autoScalingGroup:", with: ":scalingPolicy:"), name: "example")]
        for group in groups {
            let fixture = AutoScalingInsightsFixture()
            await assertError(.invalidResponse) { _ = try await fixture.service.loadInstanceRefreshes(scope: scope, group: group) }
            let requests = await fixture.requests()
            XCTAssertTrue(requests.refreshes.isEmpty)
        }
    }

    func testLegalGroupWhitespaceAndControlsPreserveExactDetailQueries() async throws {
        for name in [" ", "bad\nname", "\t", "\r\n"] {
            let group = asgInsightsGroup(name: name)
            let fixture = AutoScalingInsightsFixture(templatePages: [.init(launchTemplateVersions: [asgInsightsVersion()])],
                refreshPages: [.init(instanceRefreshes: [.init(autoScalingGroupName: name, instanceRefreshId: "refresh-1")])])
            let templates = try await fixture.service.loadTemplateVersions(scope: asgServiceScope(), group: group, template: asgInsightsTemplate)
            let refreshes = try await fixture.service.loadInstanceRefreshes(scope: asgServiceScope(), group: group)
            XCTAssertEqual(templates.first?.reference, asgInsightsTemplate)
            XCTAssertEqual(refreshes.first?.groupName, name)
            let requests = await fixture.requests()
            XCTAssertEqual(requests.templates.count, 1)
            XCTAssertEqual(requests.templates.first?.launchTemplateId, asgInsightsTemplate.templateID)
            XCTAssertEqual(requests.refreshes.map(\.autoScalingGroupName), [name])
        }
    }

    func testRefreshesPageExactlySelectedGroupAndFilterSixWeekWindow() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fixture = AutoScalingInsightsFixture(refreshPages: [
            .init(instanceRefreshes: [.init(autoScalingGroupName: "example", instanceRefreshId: "one", startTime: now)], nextToken: "next"),
            .init(instanceRefreshes: [.init(autoScalingGroupName: "example", instanceRefreshId: "old", startTime: now.addingTimeInterval(-43 * 86400)),
                                      .init(autoScalingGroupName: "example", instanceRefreshId: "unknown")])])
        let rows = try await fixture.service.loadInstanceRefreshes(scope: asgServiceScope(), group: asgInsightsGroup(), now: now)
        XCTAssertEqual(rows.map(\.id), ["one", "unknown"])
        let requests = await fixture.requests()
        XCTAssertEqual(requests.refreshes.map(\.autoScalingGroupName), ["example", "example"])
        XCTAssertEqual(requests.refreshes.map(\.nextToken), [nil, "next"])
        XCTAssertTrue(requests.refreshes.allSatisfy { $0.maxRecords == 100 && $0.instanceRefreshIds == nil })
        XCTAssertNil(rows.last?.percentageComplete)
        XCTAssertNil(rows.last?.instancesRemaining)
    }

    func testRefreshResponseGroupAndProgressAreValidated() async {
        let invalid: [AutoScaling.InstanceRefresh] = [.init(autoScalingGroupName: "other", instanceRefreshId: "id"),
            .init(autoScalingGroupName: "example", instanceRefreshId: nil),
            .init(autoScalingGroupName: "example", instanceRefreshId: "id", percentageComplete: 101),
            .init(autoScalingGroupName: "example", instanceRefreshId: "id", instancesToUpdate: -1)]
        for raw in invalid {
            let fixture = AutoScalingInsightsFixture(refreshPages: [.init(instanceRefreshes: [raw])])
            await assertError(.invalidResponse) { _ = try await fixture.service.loadInstanceRefreshes(scope: asgServiceScope(), group: asgInsightsGroup()) }
        }
    }

    func testDuplicateRefreshesAndTemplateVersionsAreRejected() async {
        let row = AutoScaling.InstanceRefresh(autoScalingGroupName: "example", instanceRefreshId: "same")
        let fixture = AutoScalingInsightsFixture(templatePages: [.init(launchTemplateVersions: [asgInsightsVersion(), asgInsightsVersion()])],
            refreshPages: [.init(instanceRefreshes: [row], nextToken: "next"), .init(instanceRefreshes: [row])])
        await assertError(.invalidResponse) { _ = try await fixture.service.loadInstanceRefreshes(scope: asgServiceScope(), group: asgInsightsGroup()) }
        await assertError(.invalidResponse) { _ = try await fixture.service.loadTemplateVersions(scope: asgServiceScope(), group: asgInsightsGroup(), template: asgInsightsTemplate) }
    }

    func testBlankAndCyclicPaginationAreRejectedForBothAPIs() async {
        for token in [" ", "next"] {
            let fixture = AutoScalingInsightsFixture(templatePages: [.init(nextToken: token), .init(nextToken: token)],
                refreshPages: [.init(nextToken: token), .init(nextToken: token)])
            await assertError(.incompletePagination) { _ = try await fixture.service.loadTemplateVersions(scope: asgServiceScope(), group: asgInsightsGroup(), template: asgInsightsTemplate) }
            await assertError(.incompletePagination) { _ = try await fixture.service.loadInstanceRefreshes(scope: asgServiceScope(), group: asgInsightsGroup()) }
        }
    }

    func testPaginationBudgetStopsBothAPIsAtOneThousand() async {
        let fixture = AutoScalingInsightsFixture(templatePages: (0..<1000).map { .init(nextToken: "template-\($0)") },
            refreshPages: (0..<1000).map { .init(nextToken: "refresh-\($0)") })
        await assertError(.incompletePagination) { _ = try await fixture.service.loadTemplateVersions(scope: asgServiceScope(), group: asgInsightsGroup(), template: asgInsightsTemplate) }
        await assertError(.incompletePagination) { _ = try await fixture.service.loadInstanceRefreshes(scope: asgServiceScope(), group: asgInsightsGroup()) }
        let requests = await fixture.requests()
        XCTAssertEqual(requests.templates.count, 1000)
        XCTAssertEqual(requests.refreshes.count, 1000)
    }

    func testLaterPageFailureDoesNotReturnPartialSuccess() async {
        let fixture = AutoScalingInsightsFixture(refreshPages: [.init(instanceRefreshes: [.init(autoScalingGroupName: "example", instanceRefreshId: "one")], nextToken: "next")], failTemplates: false, failAt: 1)
        await assertError(.refreshesPermission) { _ = try await fixture.service.loadInstanceRefreshes(scope: asgServiceScope(), group: asgInsightsGroup()) }
        let templateFixture = AutoScalingInsightsFixture(templatePages: [.init(launchTemplateVersions: [asgInsightsVersion()], nextToken: "next")], failTemplates: true, failAt: 1)
        await assertError(.templatesPermission) { _ = try await templateFixture.service.loadTemplateVersions(scope: asgServiceScope(), group: asgInsightsGroup(), template: asgInsightsTemplate) }
    }

    func testTemplatesCompleteAnEmptyPageBeforeTheExactVersion() async throws {
        let fixture = AutoScalingInsightsFixture(templatePages: [.init(nextToken: "next"), .init(launchTemplateVersions: [asgInsightsVersion()])])
        let rows = try await fixture.service.loadTemplateVersions(scope: asgServiceScope(), group: asgInsightsGroup(), template: asgInsightsTemplate)
        XCTAssertEqual(rows.map(\.version), [3])
        let requests = await fixture.requests()
        XCTAssertEqual(requests.templates.map(\.nextToken), [nil, "next"])
        XCTAssertTrue(requests.templates.allSatisfy { $0.versions == ["$Latest"] && $0.resolveAlias == false })
    }

    func testPermissionNetworkThrottleAndUnknownErrorsAreSanitized() async {
        let cases: [(Error, AutoScalingInsightsError)] = [(ASGFixtureError("UnauthorizedOperation"), .templatesPermission),
            (URLError(.notConnectedToInternet), .network), (ASGFixtureError("Throttling"), .throttled),
            (ASGFixtureError("InvalidNextToken"), .incompletePagination), (ASGFixtureError("private-code"), .failed)]
        for (failure, expected) in cases {
            let fixture = AutoScalingInsightsFixture(failTemplates: true, failure: failure)
            await assertError(expected) { _ = try await fixture.service.loadTemplateVersions(scope: asgServiceScope(), group: asgInsightsGroup(), template: asgInsightsTemplate) }
            XCTAssertFalse(expected.localizedDescription.contains("private"))
        }
    }

    func testCancellationAfterNonCooperativeResponseDoesNotContinuePagination() async {
        let gate = AutoScalingServiceRequestGate()
        let fixture = AutoScalingInsightsFixture(refreshPages: [.init(nextToken: "next")], gate: gate)
        let task = Task { try await fixture.service.loadInstanceRefreshes(scope: asgServiceScope(), group: asgInsightsGroup()) }
        await gate.waitForEntry()
        task.cancel()
        await gate.open()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let requests = await fixture.requests()
        XCTAssertEqual(requests.refreshes.count, 1)
    }

    func testEmptyTemplatesAndRefreshesAreValid() async throws {
        let fixture = AutoScalingInsightsFixture()
        let templates = try await fixture.service.loadTemplateVersions(scope: asgServiceScope(), group: asgInsightsGroup(), template: asgInsightsTemplate)
        let refreshes = try await fixture.service.loadInstanceRefreshes(scope: asgServiceScope(), group: asgInsightsGroup())
        XCTAssertTrue(templates.isEmpty)
        XCTAssertTrue(refreshes.isEmpty)
    }

    private func assertError(_ expected: AutoScalingInsightsError, operation: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? AutoScalingInsightsError, expected, file: file, line: line) }
    }
}
