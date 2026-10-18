import Foundation
import SotoAutoScaling
import XCTest
@testable import AWSPlatform

final class AWSAutoScalingServiceTests: XCTestCase {
    func testGroupsFollowAllPagesIncludingEmptyPageAndKeepRequestsReadOnly() async throws {
        let fixture = AutoScalingServiceFixture(groupPages: [
            .init(autoScalingGroups: [asgRawGroup("z-group")], nextToken: "empty"),
            .init(autoScalingGroups: [], nextToken: "last"), .init(autoScalingGroups: [asgRawGroup("a-group")])
        ])
        let groups = try await fixture.service.loadGroups(scope: asgServiceScope())
        XCTAssertEqual(groups.map(\.name), ["a-group", "z-group"])
        let requests = await fixture.requests()
        XCTAssertEqual(requests.groups.map(\.nextToken), [nil, "empty", "last"])
        XCTAssertTrue(requests.groups.allSatisfy {
            $0.maxRecords == 100 && $0.includeInstances == true && $0.autoScalingGroupNames == nil && $0.filters == nil
        })
        XCTAssertEqual(requests.total, 3)
    }

    func testPoliciesFollowAllPagesAndAlwaysFilterBySelectedGroup() async throws {
        let fixture = AutoScalingServiceFixture(policyPages: [
            .init(nextToken: "empty", scalingPolicies: [asgRawPolicy("z-policy")]),
            .init(nextToken: "last", scalingPolicies: []), .init(scalingPolicies: [asgRawPolicy("a-policy")])
        ])
        let policies = try await fixture.service.loadPolicies(scope: asgServiceScope(), group: asgServiceGroup())
        XCTAssertEqual(policies.map(\.name), ["a-policy", "z-policy"])
        let requests = await fixture.requests()
        XCTAssertEqual(requests.policies.map(\.nextToken), [nil, "empty", "last"])
        XCTAssertTrue(requests.policies.allSatisfy {
            $0.maxRecords == 100 && $0.autoScalingGroupName == "example" && $0.policyNames == nil && $0.policyTypes == nil
        })
        XCTAssertEqual(requests.total, 3)
    }

    func testActivitiesFollowAllPagesExcludeDeletedGroupsAndPreserveServiceOrder() async throws {
        let fixture = AutoScalingServiceFixture(activityPages: [
            .init(activities: [asgRawActivity("z-activity", arn: asgServiceARN())], nextToken: "empty"),
            .init(activities: [], nextToken: "last"), .init(activities: [asgRawActivity("a-activity", arn: asgServiceARN())])
        ])
        let activities = try await fixture.service.loadActivities(scope: asgServiceScope(), group: asgServiceGroup())
        XCTAssertEqual(activities.map(\.activityID), ["z-activity", "a-activity"])
        let requests = await fixture.requests()
        XCTAssertEqual(requests.activities.map(\.nextToken), [nil, "empty", "last"])
        XCTAssertTrue(requests.activities.allSatisfy {
            $0.maxRecords == 100 && $0.autoScalingGroupName == "example" && $0.includeDeletedGroups == false
                && $0.activityIds == nil && $0.filters == nil
        })
        XCTAssertEqual(requests.total, 3)
    }

    func testAllOperationsAcceptMissingCollectionsAndEmptyFinalTokens() async throws {
        let fixture = AutoScalingServiceFixture(groupPages: [.init(nextToken: "")], policyPages: [.init(nextToken: "")],
                                                activityPages: [.init(nextToken: "")])
        for operation in AutoScalingServiceFixture.Operation.allCases {
            let count = try await Self.load(operation, service: fixture.service)
            XCTAssertEqual(count, 0)
        }
    }

    func testAllOperationsRejectBlankRepeatedAndCyclicTokens() async {
        for tokens in [[" \n"], ["repeat", "repeat"], ["a", "b", "a"]] {
            let fixture = AutoScalingServiceFixture(groupPages: tokens.map { .init(nextToken: $0) },
                policyPages: tokens.map { .init(nextToken: $0) }, activityPages: tokens.map { .init(nextToken: $0) })
            for operation in AutoScalingServiceFixture.Operation.allCases {
                await assertError(AutoScalingError.incompletePagination) { _ = try await Self.load(operation, service: fixture.service) }
            }
            let requests = await fixture.requests()
            XCTAssertEqual(requests.total, tokens.count * 3)
        }
    }

    func testAllOperationsStopAtPageBudget() async {
        let tokens = (0..<1_000).map { "page-\($0)" }
        let fixture = AutoScalingServiceFixture(groupPages: tokens.map { .init(nextToken: $0) },
            policyPages: tokens.map { .init(nextToken: $0) }, activityPages: tokens.map { .init(nextToken: $0) })
        for operation in AutoScalingServiceFixture.Operation.allCases {
            await assertError(AutoScalingError.incompletePagination) { _ = try await Self.load(operation, service: fixture.service) }
        }
        let requests = await fixture.requests()
        XCTAssertEqual(requests.total, 3_000)
    }

    func testAllOperationsCanFinishOnLastAllowedPage() async throws {
        let tokens = (0..<999).map { "page-\($0)" }
        var groups: [AutoScaling.AutoScalingGroupsType] = tokens.map { .init(nextToken: $0) }
        var policies: [AutoScaling.PoliciesType] = tokens.map { .init(nextToken: $0) }
        var activities: [AutoScaling.ActivitiesType] = tokens.map { .init(nextToken: $0) }
        groups.append(.init(autoScalingGroups: [asgRawGroup()]))
        policies.append(.init(scalingPolicies: [asgRawPolicy()]))
        activities.append(.init(activities: [asgRawActivity(arn: asgServiceARN())]))
        let fixture = AutoScalingServiceFixture(groupPages: groups, policyPages: policies, activityPages: activities)
        for operation in AutoScalingServiceFixture.Operation.allCases {
            let count = try await Self.load(operation, service: fixture.service)
            XCTAssertEqual(count, 1)
        }
        let requests = await fixture.requests()
        XCTAssertEqual(requests.total, 3_000)
    }

    func testLaterPageFailureNeverReturnsPartialResults() async {
        for operation in AutoScalingServiceFixture.Operation.allCases {
            let fixture = AutoScalingServiceFixture(groupPages: [.init(autoScalingGroups: [asgRawGroup()], nextToken: "next")],
                policyPages: [.init(nextToken: "next", scalingPolicies: [asgRawPolicy()])],
                activityPages: [.init(activities: [asgRawActivity(arn: asgServiceARN())], nextToken: "next")], failOperation: operation, failAt: 1)
            let expected: AWSAutoScalingService.RequestError
            switch operation {
            case .groups: expected = .groupsPermission
            case .policies: expected = .policiesPermission
            case .activities: expected = .activitiesPermission
            }
            await assertError(expected) { _ = try await Self.load(operation, service: fixture.service) }
        }
    }

    func testAllOperationsRejectDuplicateIdentityAcrossPages() async {
        let fixture = AutoScalingServiceFixture(groupPages: [
            .init(autoScalingGroups: [asgRawGroup()], nextToken: "next"), .init(autoScalingGroups: [asgRawGroup()])
        ], policyPages: [
            .init(nextToken: "next", scalingPolicies: [asgRawPolicy()]), .init(scalingPolicies: [asgRawPolicy()])
        ], activityPages: [
            .init(activities: [asgRawActivity(arn: asgServiceARN())], nextToken: "next"),
            .init(activities: [asgRawActivity(arn: asgServiceARN())])
        ])
        for operation in AutoScalingServiceFixture.Operation.allCases {
            await assertError(AutoScalingError.invalidResponse) { _ = try await Self.load(operation, service: fixture.service) }
        }
    }

    func testSameGroupNameWithDifferentARNIsRejected() async {
        let fixture = AutoScalingServiceFixture(groupPages: [.init(autoScalingGroups: [
            asgRawGroup(), asgRawGroup(arn: asgServiceARN(uniqueID: "recreated"))
        ])])
        await assertError(AutoScalingError.invalidResponse) { _ = try await fixture.service.loadGroups(scope: asgServiceScope()) }
    }

    func testGroupIdentityMustMatchPartitionServiceRegionAccountTypeAndName() async {
        let valid = asgServiceARN()
        for invalid in [valid.replacingOccurrences(of: "arn:aws:", with: "arn:aws-cn:"),
                        valid.replacingOccurrences(of: ":autoscaling:", with: ":ec2:"),
                        valid.replacingOccurrences(of: "eu-west-1", with: "us-east-1"),
                        valid.replacingOccurrences(of: "111122223333", with: "999988887777"),
                        valid.replacingOccurrences(of: ":autoScalingGroup:", with: ":scalingPolicy:"),
                        valid.replacingOccurrences(of: "Name/example", with: "Name/other"),
                        valid + ":extra", valid.replacingOccurrences(of: "group-identity", with: ""),
                        valid.replacingOccurrences(of: "group-identity", with: " "),
                        valid.replacingOccurrences(of: "group-identity", with: "bad\nidentity"),
                        valid.replacingOccurrences(of: "group-identity", with: "injected:segment")] {
            let fixture = AutoScalingServiceFixture(groupPages: [.init(autoScalingGroups: [asgRawGroup(arn: invalid)])])
            await assertError(AutoScalingError.invalidResponse) { _ = try await fixture.service.loadGroups(scope: asgServiceScope()) }
        }
    }

    func testGroupIdentityRequiresBothARNAndName() async {
        for raw in [AutoScaling.AutoScalingGroup(), .init(autoScalingGroupARN: asgServiceARN()),
                    .init(autoScalingGroupName: "example"), asgRawGroup("")] {
            let fixture = AutoScalingServiceFixture(groupPages: [.init(autoScalingGroups: [raw])])
            await assertError(AutoScalingError.invalidResponse) { _ = try await fixture.service.loadGroups(scope: asgServiceScope()) }
        }
    }

    func testChinaAndGovCloudARNsMatchTheirCurrentScopes() async throws {
        for (region, partition) in [("cn-north-1", "aws-cn"), ("us-gov-west-1", "aws-us-gov")] {
            let arn = "arn:\(partition):autoscaling:\(region):111122223333:autoScalingGroup:identity:autoScalingGroupName/example"
            let fixture = AutoScalingServiceFixture(groupPages: [.init(autoScalingGroups: [asgRawGroup(arn: arn)])])
            let groups = try await fixture.service.loadGroups(scope: asgServiceScope(region: region, partition: partition))
            XCTAssertEqual(groups.first?.arn, arn)
        }
    }

    func testGroupNamesAndTagKeysPreserveLegalUnicodeAndSpaces() async throws {
        let name = " 应用 group "
        let raw = AutoScaling.AutoScalingGroup(autoScalingGroupARN: asgServiceARN(name), autoScalingGroupName: name,
                                               tags: [.init(key: " Team ", value: "运营")])
        let fixture = AutoScalingServiceFixture(groupPages: [.init(autoScalingGroups: [raw])])
        let groups = try await fixture.service.loadGroups(scope: asgServiceScope())
        XCTAssertEqual(groups.first?.name, name)
        XCTAssertEqual(groups.first?.tags.first?.key, " Team ")
        XCTAssertEqual(groups.first?.tags.first?.value, "运营")
    }

    func testGroupNamesPreserveWhitespaceAndControlsWithMatchingARN() async throws {
        for name in [" ", "bad\nname", "\t"] {
            let fixture = AutoScalingServiceFixture(groupPages: [.init(autoScalingGroups: [asgRawGroup(name)])])
            let groups = try await fixture.service.loadGroups(scope: asgServiceScope())
            XCTAssertEqual(groups.first?.name, name)
            XCTAssertEqual(groups.first?.arn, asgServiceARN(name))
        }
    }

    func testTagKeysPreserveWhitespaceExactly() async throws {
        let keys = [" ", " env ", "\t", "\r\n"]
        let raw = AutoScaling.AutoScalingGroup(autoScalingGroupARN: asgServiceARN(), autoScalingGroupName: "example",
                                               tags: keys.map { .init(key: $0) })
        let fixture = AutoScalingServiceFixture(groupPages: [.init(autoScalingGroups: [raw])])
        let groups = try await fixture.service.loadGroups(scope: asgServiceScope())
        XCTAssertEqual(groups.first?.tags.map(\.key), keys.sorted())
    }

    func testPolicyNamesPreserveWhitespaceAndColonWithMatchingARN() async throws {
        for name in [" scale ", "scale:worker", "\tpolicy\r\n"] {
            let raw = asgRawPolicy(name)
            let fixture = AutoScalingServiceFixture(policyPages: [.init(scalingPolicies: [raw])])
            let policies = try await fixture.service.loadPolicies(scope: asgServiceScope(), group: asgServiceGroup())
            XCTAssertEqual(policies.first?.name, name)
            XCTAssertEqual(policies.first?.arn, raw.policyARN)
        }
    }

    func testPoliciesRequireGroupNameAndScopedPolicyARN() async {
        let raw = asgRawPolicy()
        for invalid in [raw.policyARN!.replacingOccurrences(of: "111122223333", with: "999988887777"),
                        raw.policyARN!.replacingOccurrences(of: "eu-west-1", with: "us-east-1"),
                        raw.policyARN!.replacingOccurrences(of: "arn:aws:", with: "arn:aws-cn:"),
                        raw.policyARN!.replacingOccurrences(of: "Name/example", with: "Name/other"),
                        raw.policyARN!.replacingOccurrences(of: "Name/scale", with: "Name/other"), raw.policyARN! + ":extra"] {
            let fixture = AutoScalingServiceFixture(policyPages: [.init(scalingPolicies: [asgRawPolicy(arn: invalid)])])
            await assertError(AutoScalingError.invalidResponse) {
                _ = try await fixture.service.loadPolicies(scope: asgServiceScope(), group: asgServiceGroup())
            }
        }
        for policy in [AutoScaling.ScalingPolicy(), asgRawPolicy(""), asgRawPolicy(group: "other"),
                       .init(autoScalingGroupName: "example", policyARN: raw.policyARN),
                       .init(autoScalingGroupName: "example", policyName: "scale")] {
            let fixture = AutoScalingServiceFixture(policyPages: [.init(scalingPolicies: [policy])])
            await assertError(AutoScalingError.invalidResponse) {
                _ = try await fixture.service.loadPolicies(scope: asgServiceScope(), group: asgServiceGroup())
            }
        }
    }

    func testActivitiesRejectOldRecreatedGroupEvenWhenNameMatches() async {
        for activity in [asgRawActivity(arn: asgServiceARN(uniqueID: "old-deleted")), asgRawActivity(group: "other", arn: asgServiceARN()),
                         AutoScaling.Activity(activityId: "activity"),
                         .init(autoScalingGroupARN: asgServiceARN(), autoScalingGroupName: "example")] {
            let fixture = AutoScalingServiceFixture(activityPages: [.init(activities: [activity])])
            await assertError(AutoScalingError.invalidResponse) {
                _ = try await fixture.service.loadActivities(scope: asgServiceScope(), group: asgServiceGroup())
            }
        }
    }

    func testActivitiesRequireGroupARN() async {
        for arn: String? in [nil, "", " \n"] {
            let fixture = AutoScalingServiceFixture(activityPages: [.init(activities: [asgRawActivity(arn: arn)])])
            await assertError(AutoScalingError.invalidResponse) {
                _ = try await fixture.service.loadActivities(scope: asgServiceScope(), group: asgServiceGroup())
            }
        }
    }

    func testActivitiesPreserveOptionalFieldsWithMatchingGroupARN() async throws {
        let fixture = AutoScalingServiceFixture(activityPages: [.init(activities: [asgRawActivity(arn: asgServiceARN())])])
        let activities = try await fixture.service.loadActivities(scope: asgServiceScope(), group: asgServiceGroup())
        let activity = try XCTUnwrap(activities.first)
        XCTAssertEqual(activity.groupARN, asgServiceARN())
        XCTAssertNil(activity.groupState)
        XCTAssertNil(activity.statusCode)
        XCTAssertNil(activity.statusMessage)
        XCTAssertNil(activity.description)
        XCTAssertNil(activity.cause)
        XCTAssertNil(activity.details)
        XCTAssertNil(activity.progress)
        XCTAssertNil(activity.startedAt)
        XCTAssertNil(activity.endedAt)
    }

    func testInvalidScopeStopsAllOperationsBeforeAnyLoader() async {
        for scope in [asgServiceScope(profile: ""), asgServiceScope(account: "bad"), asgServiceScope(region: "invalid"),
                      asgServiceScope(region: "cn-north-1", partition: "aws")] {
            let fixture = AutoScalingServiceFixture()
            for operation in AutoScalingServiceFixture.Operation.allCases {
                await assertError(AutoScalingError.invalidScope) { _ = try await Self.load(operation, service: fixture.service, scope: scope) }
            }
            let requests = await fixture.requests()
            XCTAssertEqual(requests.total, 0)
        }
    }

    func testDetailRequestsRejectMismatchedSelectedGroupBeforeAnyLoader() async {
        let fixture = AutoScalingServiceFixture()
        let group = ASGGroup(arn: asgServiceARN().replacingOccurrences(of: "111122223333", with: "999988887777"), name: "example")
        await assertError(AutoScalingError.invalidResponse) { _ = try await fixture.service.loadPolicies(scope: asgServiceScope(), group: group) }
        await assertError(AutoScalingError.invalidResponse) { _ = try await fixture.service.loadActivities(scope: asgServiceScope(), group: group) }
        let requests = await fixture.requests()
        XCTAssertEqual(requests.total, 0)
    }

    func testGroupMapsWeightedCapacityTemplatesNetworkingAndMemberMetadata() async throws {
        let raw = AutoScaling.AutoScalingGroup(autoScalingGroupARN: asgServiceARN(), autoScalingGroupName: "example",
            availabilityZones: ["eu-west-1a"], capacityRebalance: true, createdTime: Date(timeIntervalSince1970: 100),
            defaultCooldown: 300, defaultInstanceWarmup: -1, desiredCapacity: 16, desiredCapacityType: "vcpu",
            healthCheckGracePeriod: 120, healthCheckType: "EC2,ELB", instances: [
                .init(availabilityZone: "eu-west-1a", healthStatus: "FutureHealth", instanceId: "i-example", instanceType: "m7i.large",
                      launchConfigurationName: "legacy", launchTemplate: .init(launchTemplateId: "lt-member", version: "$Default"),
                      lifecycleState: .inService, protectedFromScaleIn: false, weightedCapacity: "2")
            ], launchConfigurationName: "legacy", launchTemplate: .init(launchTemplateId: "lt-main", launchTemplateName: "main", version: "$Latest"),
            loadBalancerNames: ["classic"], maxSize: 64, minSize: 8, newInstancesProtectedFromScaleIn: true,
            serviceLinkedRoleARN: "arn:aws:iam::111122223333:role/service", status: "FutureStatus",
            suspendedProcesses: [.init(processName: "Launch", suspensionReason: "operator")],
            tags: [.init(key: "Team", propagateAtLaunch: false, resourceId: "example", resourceType: "auto-scaling-group", value: "ops")],
            targetGroupARNs: ["target-arn"], terminationPolicies: ["OldestInstance"], vpcZoneIdentifier: "subnet-a, subnet-b")
        let fixture = AutoScalingServiceFixture(groupPages: [.init(autoScalingGroups: [raw])])
        let groups = try await fixture.service.loadGroups(scope: asgServiceScope())
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.desiredCapacity, 16)
        XCTAssertEqual(group.desiredCapacityType, "vcpu")
        XCTAssertEqual(group.minSize, 8)
        XCTAssertEqual(group.maxSize, 64)
        XCTAssertEqual(group.members.count, 1)
        XCTAssertEqual(group.members.first?.weightedCapacity, "2")
        XCTAssertEqual(group.members.first?.healthStatus, "FutureHealth")
        XCTAssertEqual(group.members.first?.lifecycleState, "InService")
        XCTAssertEqual(group.members.first?.protectedFromScaleIn, false)
        XCTAssertEqual(group.members.first?.launchTemplate?.version, "$Default")
        XCTAssertEqual(group.launchTemplate?.version, "$Latest")
        XCTAssertEqual(group.launchTemplate?.name, "main")
        XCTAssertEqual(group.subnetIDs, ["subnet-a", "subnet-b"])
        XCTAssertEqual(group.availabilityZones, ["eu-west-1a"])
        XCTAssertEqual(group.targetGroupARNs, ["target-arn"])
        XCTAssertEqual(group.loadBalancerNames, ["classic"])
        XCTAssertEqual(group.defaultInstanceWarmup, -1)
        XCTAssertEqual(group.defaultCooldown, 300)
        XCTAssertEqual(group.healthCheckType, "EC2,ELB")
        XCTAssertEqual(group.healthCheckGracePeriod, 120)
        XCTAssertEqual(group.status, "FutureStatus")
        XCTAssertEqual(group.capacityRebalance, true)
        XCTAssertEqual(group.newInstancesProtectedFromScaleIn, true)
        XCTAssertEqual(group.suspendedProcesses, [.init(name: "Launch", reason: "operator")])
        XCTAssertEqual(group.tags, [.init(key: "Team", value: "ops", propagateAtLaunch: false)])
        XCTAssertEqual(group.createdAt, Date(timeIntervalSince1970: 100))
    }

    func testMixedInstancesKeepWeightsRequirementsTemplatesAndOnDemandUnits() async throws {
        let mixed = AutoScaling.MixedInstancesPolicy(instancesDistribution: .init(onDemandAllocationStrategy: "prioritized",
            onDemandBaseCapacity: 4, onDemandPercentageAboveBaseCapacity: 25, spotAllocationStrategy: "capacity-optimized"),
            launchTemplate: .init(launchTemplateSpecification: .init(launchTemplateId: "lt-main", version: "$Default"), overrides: [
                .init(instanceType: "m7i.large", launchTemplateSpecification: .init(launchTemplateName: "override", version: "$Latest"), weightedCapacity: "4"),
                .init(instanceRequirements: .init(memoryMiB: .init(min: 4096), vCpuCount: .init(min: 2)))
            ]))
        let raw = AutoScaling.AutoScalingGroup(autoScalingGroupARN: asgServiceARN(), autoScalingGroupName: "example",
                                               desiredCapacityType: "memory-mib", mixedInstancesPolicy: mixed)
        let fixture = AutoScalingServiceFixture(groupPages: [.init(autoScalingGroups: [raw])])
        let groups = try await fixture.service.loadGroups(scope: asgServiceScope())
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.desiredCapacityType, "memory-mib")
        XCTAssertEqual(group.mixedInstances?.onDemandBaseCapacity, 4)
        XCTAssertEqual(group.mixedInstances?.onDemandPercentageAboveBaseCapacity, 25)
        XCTAssertEqual(group.mixedInstances?.onDemandAllocationStrategy, "prioritized")
        XCTAssertEqual(group.mixedInstances?.spotAllocationStrategy, "capacity-optimized")
        XCTAssertEqual(group.mixedInstances?.launchTemplate?.version, "$Default")
        XCTAssertEqual(group.mixedInstances?.overrides.first?.weightedCapacity, "4")
        XCTAssertEqual(group.mixedInstances?.overrides.first?.launchTemplate?.version, "$Latest")
        XCTAssertEqual(group.mixedInstances?.overrides.first?.usesInstanceRequirements, false)
        XCTAssertEqual(group.mixedInstances?.overrides.last?.usesInstanceRequirements, true)
        XCTAssertNil(group.mixedInstances?.overrides.last?.instanceType)
    }

    func testMissingFieldsRemainUnknownAndZeroCapacityRemainsZero() async throws {
        let raw = AutoScaling.AutoScalingGroup(autoScalingGroupARN: asgServiceARN(), autoScalingGroupName: "example", desiredCapacity: 0)
        let fixture = AutoScalingServiceFixture(groupPages: [.init(autoScalingGroups: [raw])])
        let groups = try await fixture.service.loadGroups(scope: asgServiceScope())
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.desiredCapacity, 0)
        XCTAssertNil(group.desiredCapacityType)
        XCTAssertNil(group.newInstancesProtectedFromScaleIn)
        XCTAssertNil(group.capacityRebalance)
        XCTAssertNil(group.status)
        XCTAssertNil(group.minSize)
        XCTAssertNil(group.launchTemplate)
        XCTAssertNil(group.mixedInstances)
        XCTAssertTrue(group.members.isEmpty)
    }

    func testGroupRejectsDuplicateMembersTagsAndMismatchedTagOwnership() async {
        let raws: [AutoScaling.AutoScalingGroup] = [
            .init(autoScalingGroupARN: asgServiceARN(), autoScalingGroupName: "example", instances: [.init(instanceId: "i-a"), .init(instanceId: "i-a")]),
            .init(autoScalingGroupARN: asgServiceARN(), autoScalingGroupName: "example", instances: [.init()]),
            .init(autoScalingGroupARN: asgServiceARN(), autoScalingGroupName: "example", tags: [.init()]),
            .init(autoScalingGroupARN: asgServiceARN(), autoScalingGroupName: "example", tags: [.init(key: "")]),
            .init(autoScalingGroupARN: asgServiceARN(), autoScalingGroupName: "example", tags: [.init(key: "Name"), .init(key: "Name")]),
            .init(autoScalingGroupARN: asgServiceARN(), autoScalingGroupName: "example", tags: [.init(key: "Name", resourceId: "other")]),
            .init(autoScalingGroupARN: asgServiceARN(), autoScalingGroupName: "example", tags: [.init(key: "Name", resourceType: "other")])
        ]
        for raw in raws {
            let fixture = AutoScalingServiceFixture(groupPages: [.init(autoScalingGroups: [raw])])
            await assertError(AutoScalingError.invalidResponse) { _ = try await fixture.service.loadGroups(scope: asgServiceScope()) }
        }
    }

    func testPoliciesPreserveTargetStepPredictiveAndOptionalBooleanMetadata() async throws {
        let base = asgRawPolicy()
        let policy = AutoScaling.ScalingPolicy(adjustmentType: "FutureAdjustment", alarms: [.init(alarmARN: "alarm-arn", alarmName: "high")],
            autoScalingGroupName: "example", cooldown: 120, enabled: false, estimatedInstanceWarmup: 60,
            metricAggregationType: "Average", minAdjustmentMagnitude: 2, policyARN: base.policyARN, policyName: "scale", policyType: "FuturePolicy",
            predictiveScalingConfiguration: .init(mode: .forecastOnly), scalingAdjustment: -2,
            stepAdjustments: [.init(metricIntervalLowerBound: nil, metricIntervalUpperBound: 10, scalingAdjustment: -1)],
            targetTrackingConfiguration: .init(disableScaleIn: nil, predefinedMetricSpecification: .init(predefinedMetricType: .asgAverageCPUUtilization), targetValue: 40))
        let fixture = AutoScalingServiceFixture(policyPages: [.init(scalingPolicies: [policy])])
        let policies = try await fixture.service.loadPolicies(scope: asgServiceScope(), group: asgServiceGroup())
        let result = try XCTUnwrap(policies.first)
        XCTAssertEqual(result.policyType, "FuturePolicy")
        XCTAssertEqual(result.adjustmentType, "FutureAdjustment")
        XCTAssertEqual(result.enabled, false)
        XCTAssertEqual(result.scalingAdjustment, -2)
        XCTAssertEqual(result.cooldown, 120)
        XCTAssertEqual(result.estimatedInstanceWarmup, 60)
        XCTAssertEqual(result.minAdjustmentMagnitude, 2)
        XCTAssertEqual(result.targetValue, 40)
        XCTAssertEqual(result.targetMetricType, "ASGAverageCPUUtilization")
        XCTAssertEqual(result.usesCustomizedMetric, false)
        XCTAssertNil(result.disableScaleIn)
        XCTAssertEqual(result.predictiveMode, "ForecastOnly")
        XCTAssertEqual(result.alarms, [.init(arn: "alarm-arn", name: "high")])
        XCTAssertEqual(result.stepAdjustments, [.init(upperBound: 10, adjustment: -1)])
    }

    func testActivitiesMapRealARNStatusAndTimestamps() async throws {
        let raw = AutoScaling.Activity(activityId: "activity", autoScalingGroupARN: asgServiceARN(), autoScalingGroupName: "example",
            autoScalingGroupState: "FutureState", cause: "manual", description: "launch", details: "{}", endTime: Date(timeIntervalSince1970: 20),
            progress: 100, startTime: Date(timeIntervalSince1970: 10), statusCode: .successful, statusMessage: "complete")
        let fixture = AutoScalingServiceFixture(activityPages: [.init(activities: [raw])])
        let activities = try await fixture.service.loadActivities(scope: asgServiceScope(), group: asgServiceGroup())
        let value = try XCTUnwrap(activities.first)
        XCTAssertEqual(value.groupARN, asgServiceARN())
        XCTAssertEqual(value.groupState, "FutureState")
        XCTAssertEqual(value.statusCode, "Successful")
        XCTAssertEqual(value.description, "launch")
        XCTAssertEqual(value.cause, "manual")
        XCTAssertEqual(value.details, "{}")
        XCTAssertEqual(value.progress, 100)
        XCTAssertEqual(value.startedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(value.endedAt, Date(timeIntervalSince1970: 20))
    }

    func testErrorsUseFixedSafeMessagesRatherThanProviderDetails() async {
        let cases: [(Error, Error)] = [(ASGFixtureError("ExpiredToken"), AWSAutoScalingService.RequestError.credentials),
            (URLError(.notConnectedToInternet), AWSAutoScalingService.RequestError.network),
            (ASGFixtureError("Throttling"), AWSAutoScalingService.RequestError.throttled),
            (ASGFixtureError("InvalidNextToken"), AutoScalingError.incompletePagination),
            (ASGFixtureError("UnknownPrivateError"), AWSAutoScalingService.RequestError.failed)]
        for (failure, expected) in cases {
            for operation in AutoScalingServiceFixture.Operation.allCases {
                let fixture = AutoScalingServiceFixture(failOperation: operation, failure: failure)
                await assertError(expected) { _ = try await Self.load(operation, service: fixture.service) }
            }
        }
    }

    func testCancellationBeforeRequestMakesNoCalls() async {
        let fixture = AutoScalingServiceFixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.service.loadGroups(scope: asgServiceScope())
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        let requests = await fixture.requests()
        XCTAssertEqual(requests.total, 0)
    }

    func testCancellationAfterEachOperationResponseRejectsLateData() async {
        for operation in AutoScalingServiceFixture.Operation.allCases {
            let gate = AutoScalingServiceRequestGate()
            let fixture = AutoScalingServiceFixture(groupPages: [.init(autoScalingGroups: [asgRawGroup()])],
                policyPages: [.init(scalingPolicies: [asgRawPolicy()])],
                activityPages: [.init(activities: [asgRawActivity(arn: asgServiceARN())])], gate: gate)
            let task = Task { try await Self.load(operation, service: fixture.service) }
            await gate.waitForEntry()
            task.cancel()
            await gate.open()
            do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
            let requests = await fixture.requests()
            XCTAssertEqual(requests.total, 1)
        }
    }

    private static func load(_ operation: AutoScalingServiceFixture.Operation, service: AWSAutoScalingService,
                      scope: MonitoringScope = asgServiceScope()) async throws -> Int {
        switch operation {
        case .groups: return try await service.loadGroups(scope: scope).count
        case .policies: return try await service.loadPolicies(scope: scope, group: asgServiceGroup()).count
        case .activities: return try await service.loadActivities(scope: scope, group: asgServiceGroup()).count
        }
    }

    private func assertError(_ expected: Error, file: StaticString = #filePath, line: UInt = #line,
                             operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected failure", file: file, line: line) }
        catch {
            XCTAssertEqual(error.localizedDescription, expected.localizedDescription, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("private-asg-token"), file: file, line: line)
        }
    }
}
