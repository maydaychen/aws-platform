import Foundation
import SotoEC2
import SotoAutoScaling
@testable import AWSPlatform

let asgInsightsTemplate = ASGLaunchTemplate(templateID: "lt-0123456789abcdef0", name: "web-template", version: "$Latest")

func asgInsightsGroup(template: ASGLaunchTemplate? = asgInsightsTemplate, name: String = "example") -> ASGGroup {
    ASGGroup(arn: asgServiceARN(name), name: name, launchTemplate: template)
}

func asgInsightsVersion(_ version: Int64 = 3, id: String = "lt-0123456789abcdef0", name: String? = "web-template",
                        creator: String? = "arn:aws:iam::111122223333:root", isDefault: Bool? = nil,
                        data: EC2.ResponseLaunchTemplateData? = nil) -> EC2.LaunchTemplateVersion {
    .init(createdBy: creator, defaultVersion: isDefault, launchTemplateData: data,
          launchTemplateId: id, launchTemplateName: name, versionNumber: version)
}

func asgInsightsModel(reference: ASGLaunchTemplate = asgInsightsTemplate, version: Int64 = 3) -> ASGTemplateVersion {
    ASGTemplateVersion(reference: reference, templateID: "lt-0123456789abcdef0", templateName: "web-template", version: version,
        isDefault: nil, description: nil, createdAt: nil, createdBy: nil, imageID: "resolve:ssm:/ami/web", instanceType: nil,
        keyName: nil, securityGroupIDs: nil, instanceProfileARN: nil, instanceProfileName: nil,
        ebsOptimized: nil, detailedMonitoring: nil)
}

func asgInsightsRefresh(id: String = "refresh-1", group: String = "example") -> ASGInstanceRefresh {
    .init(id: id, groupName: group, status: "InProgress", percentageComplete: nil, instancesRemaining: nil,
          startedAt: nil, endedAt: nil, statusReason: nil, strategy: nil)
}

actor AutoScalingInsightsFixture {
    struct Requests: Sendable {
        var templates: [EC2.DescribeLaunchTemplateVersionsRequest] = []
        var refreshes: [AutoScaling.DescribeInstanceRefreshesType] = []
    }
    private var calls = Requests()
    private let templatePages: [EC2.DescribeLaunchTemplateVersionsResult]
    private let refreshPages: [AutoScaling.DescribeInstanceRefreshesAnswer]
    private let failTemplates: Bool?
    private let failAt: Int
    private let failure: Error
    private let gate: AutoScalingServiceRequestGate?

    init(templatePages: [EC2.DescribeLaunchTemplateVersionsResult] = [.init()],
         refreshPages: [AutoScaling.DescribeInstanceRefreshesAnswer] = [.init()],
         failTemplates: Bool? = nil, failAt: Int = 0, failure: Error = ASGFixtureError("AccessDenied"),
         gate: AutoScalingServiceRequestGate? = nil) {
        self.templatePages = templatePages; self.refreshPages = refreshPages
        self.failTemplates = failTemplates; self.failAt = failAt; self.failure = failure; self.gate = gate
    }

    func requests() -> Requests { calls }

    func templates(_ request: EC2.DescribeLaunchTemplateVersionsRequest) async throws -> EC2.DescribeLaunchTemplateVersionsResult {
        let index = calls.templates.count
        calls.templates.append(request)
        if let gate { await gate.enter() }
        if failTemplates == true && index == failAt { throw failure }
        return index < templatePages.count ? templatePages[index] : .init()
    }

    func refreshes(_ request: AutoScaling.DescribeInstanceRefreshesType) async throws -> AutoScaling.DescribeInstanceRefreshesAnswer {
        let index = calls.refreshes.count
        calls.refreshes.append(request)
        if let gate { await gate.enter() }
        if failTemplates == false && index == failAt { throw failure }
        return index < refreshPages.count ? refreshPages[index] : .init()
    }

    nonisolated var service: AWSAutoScalingInsightsService {
        .init(templateLoader: { try await self.templates($0) }, refreshLoader: { try await self.refreshes($0) })
    }
}
