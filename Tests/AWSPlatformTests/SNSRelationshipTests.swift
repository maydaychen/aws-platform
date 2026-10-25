import Foundation
import XCTest
@testable import AWSPlatform

final class SNSRelationshipTests: XCTestCase {
    func testAlarmSourcesMatchExactTopicForAllThreeActionStates() {
        let selected = topic()
        let matched = alarm(
            "matched", alarmActions: [selected.arn], okActions: [selected.arn],
            insufficientDataActions: [selected.arn]
        )
        let lookalikes = [
            alarm("suffix", alarmActions: [selected.arn + "-other"]),
            alarm("subscription", alarmActions: [selected.arn + ":subscription-1"]),
            alarm("different-case", alarmActions: [selected.arn.uppercased()]),
            alarm("different-topic", alarmActions: [topic("other").arn])
        ]
        let rows = SNSRelationshipMapping.alarmSources(lookalikes + [matched], topic: selected, scope: scope())

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].alarm, matched)
        XCTAssertEqual(rows[0].triggers, ["ALARM", "OK", "INSUFFICIENT_DATA"])
        XCTAssertEqual(rows[0].target.service, .alarms)
        XCTAssertEqual(rows[0].target.resourceID, matched.arn)
        XCTAssertEqual(rows[0].id, matched.arn)
        XCTAssertTrue(rows[0].target.isValid(in: scope()))
    }

    func testDisabledAndSuppressedAlarmsRemainVisibleWithOriginalConfiguration() {
        let selected = topic()
        let disabled = CloudWatchAlarm(
            arn: alarmARN("disabled"), name: "disabled", kind: .metric, state: "OK",
            actionsEnabled: false, alarmActions: [selected.arn]
        )
        let suppression = [
            AlarmProperty(label: "Actions suppressor", value: alarmARN("maintenance")),
            AlarmProperty(label: "Suppression wait (seconds)", value: "60"),
            AlarmProperty(label: "Actions suppressed by", value: "WaitPeriod")
        ]
        let composite = CloudWatchAlarm(
            arn: alarmARN("composite"), name: "composite", kind: .composite, state: "ALARM",
            actionsEnabled: true, alarmActions: [selected.arn], configuration: suppression, rule: "ALARM(\"disabled\")"
        )
        let unknown = alarm("unknown", alarmActions: [selected.arn])
        let rows = SNSRelationshipMapping.alarmSources([disabled, composite, unknown], topic: selected, scope: scope())

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first { $0.id == disabled.arn }?.alarm.actionsEnabled, false)
        XCTAssertNil(rows.first { $0.id == unknown.arn }?.alarm.actionsEnabled)
        XCTAssertEqual(rows.first { $0.id == composite.arn }?.alarm.configuration, suppression)
        XCTAssertEqual(rows.first { $0.id == composite.arn }?.alarm.rule, "ALARM(\"disabled\")")
        XCTAssertEqual(rows.first { $0.id == composite.arn }?.alarm.kind, .composite)
    }

    func testAlarmSourcesDeduplicateAndMergeTriggersInStableOrder() {
        let selected = topic()
        let first = alarm("zeta", alarmActions: [selected.arn, selected.arn])
        let repeatWithOtherStates = alarm("zeta", okActions: [selected.arn], insufficientDataActions: [selected.arn])
        let earlier = alarm("alpha", okActions: [selected.arn])
        let rows = SNSRelationshipMapping.alarmSources(
            [first, repeatWithOtherStates, earlier, earlier], topic: selected, scope: scope()
        )

        XCTAssertEqual(rows.map { $0.alarm.name }, ["alpha", "zeta"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(rows[0].triggers, ["OK"])
        XCTAssertEqual(rows[1].triggers, ["ALARM", "OK", "INSUFFICIENT_DATA"])
        XCTAssertEqual(rows[1].alarm, first)
    }

    func testWrongTopicOrAlarmScopeAndMismatchedNamesCannotProduceNavigation() {
        let selected = topic()
        let invalidAlarms = [
            CloudWatchAlarm(arn: alarmARN("CPU", region: "eu-west-1"), name: "CPU", kind: .metric, state: "OK", alarmActions: [selected.arn]),
            CloudWatchAlarm(arn: "arn:aws:cloudwatch:us-east-1:999988887777:alarm:CPU", name: "CPU", kind: .metric, state: "OK", alarmActions: [selected.arn]),
            CloudWatchAlarm(arn: "arn:aws-cn:cloudwatch:cn-north-1:111122223333:alarm:CPU", name: "CPU", kind: .metric, state: "OK", alarmActions: [selected.arn]),
            CloudWatchAlarm(arn: alarmARN("CPU"), name: "different", kind: .metric, state: "OK", alarmActions: [selected.arn]),
            CloudWatchAlarm(arn: lambdaARN(), name: "CPU", kind: .metric, state: "OK", alarmActions: [selected.arn])
        ]
        XCTAssertTrue(SNSRelationshipMapping.alarmSources(invalidAlarms, topic: selected, scope: scope()).isEmpty)

        let valid = alarm("CPU", alarmActions: [selected.arn])
        for invalidTopic in [
            SNSTopic(arn: selected.arn, name: "different"),
            SNSTopic(arn: "arn:aws:sns:eu-west-1:111122223333:alerts", name: "alerts"),
            SNSTopic(arn: "arn:aws:sns:us-east-1:999988887777:alerts", name: "alerts"),
            SNSTopic(arn: selected.arn + ":subscription-1", name: "alerts:subscription-1")
        ] {
            XCTAssertTrue(SNSRelationshipMapping.alarmSources([valid], topic: invalidTopic, scope: scope()).isEmpty)
        }
    }

    func testAlarmResourceIDKeepsFullARNAndSupportsColonInName() {
        let arn = alarmARN("production: high CPU")
        let target = SNSRelatedResource(scope: scope(), service: .alarms, arn: arn)

        XCTAssertEqual(target?.resourceID, arn)
        XCTAssertEqual(target?.arn, arn)
        XCTAssertNil(target?.qualifier)
        XCTAssertNil(SNSRelatedResource(scope: scope(), service: .alarms, arn: alarmARN("")))
        XCTAssertNil(SNSRelatedResource(scope: scope(), service: .alarms, arn: arn + "\n"))
        XCTAssertNil(SNSRelatedResource(scope: scope(), service: .sns, arn: arn))
        XCTAssertNil(SNSRelatedResource(scope: scope(), service: .ec2, arn: arn))
        XCTAssertNil(SNSRelatedResource(scope: scope(), service: .s3, arn: arn))
    }

    func testLambdaFunctionTargetsKeepAliasVersionAndLatestQualifier() {
        for qualifier in [nil, "production", "12", "$LATEST"] as [String?] {
            let arn = lambdaARN(qualifier: qualifier)
            let target = SNSRelatedResource(scope: scope(), service: .lambda, arn: arn)

            XCTAssertEqual(target?.resourceID, "private-handler")
            XCTAssertEqual(target?.qualifier, qualifier)
            XCTAssertEqual(target?.arn, arn)
            XCTAssertEqual(target?.service, .lambda)
            XCTAssertTrue(target?.isValid(in: scope()) == true)
        }
    }

    func testLambdaARNParsingRejectsInvalidOrUnsupportedResources() {
        let invalidARNs = [
            topic().arn, alarmARN("CPU"),
            "arn:aws:lambda:us-east-1:111122223333:layer:private-handler",
            "arn:aws:lambda:us-east-1:111122223333:function:",
            lambdaARN() + ":", lambdaARN() + ":alias:extra", lambdaARN() + ":$OTHER",
            lambdaARN(name: "name with spaces"), lambdaARN(name: String(repeating: "a", count: 65)),
            lambdaARN() + "\n", "invalid"
        ]
        for arn in invalidARNs {
            XCTAssertNil(SNSRelatedResource(scope: scope(), service: .lambda, arn: arn))
        }
    }

    func testNavigationTargetRequiresTheCompleteOriginalScope() throws {
        let original = scope()
        let target = try XCTUnwrap(SNSRelatedResource(scope: original, service: .lambda, arn: lambdaARN()))
        let changedScopes = [
            scope(profileName: "other"), scope(profileRole: "DifferentRole"),
            scope(session: "different-session"), scope(profileRegion: "eu-west-1"),
            scope(configPath: "/example/other-config"), scope(credentialsPath: "/example/other-credentials"),
            scope(principal: "arn:aws:sts::111122223333:assumed-role/OtherRole/session"),
            scope(account: "999988887777"), scope(region: "eu-west-1")
        ]
        XCTAssertTrue(target.isValid(in: original))
        XCTAssertFalse(target.isValid(in: nil))
        for changed in changedScopes { XCTAssertFalse(target.isValid(in: changed)) }
    }

    func testInvalidIdentityAndCrossAccountRegionPartitionTargetsAreRejected() {
        for invalidScope in [
            scope(profileName: ""),
            scope(principal: "arn:aws:sts::999988887777:assumed-role/Test/session"),
            scope(principal: "arn:aws:sns::111122223333:unrelated"),
            scope(principal: "not-an-identity")
        ] {
            XCTAssertNil(SNSRelatedResource(scope: invalidScope, service: .lambda, arn: lambdaARN()))
        }
        for endpoint in [
            lambdaARN(account: "999988887777"), lambdaARN(region: "eu-west-1"),
            "arn:aws-cn:lambda:cn-north-1:111122223333:function:private-handler",
            "arn:aws--cn:lambda:cn-north-1:111122223333:function:private-handler"
        ] {
            XCTAssertNil(SNSRelatedResource(scope: scope(), service: .lambda, arn: endpoint))
            XCTAssertNil(SNSRelationshipMapping.lambdaTarget(subscription(endpoint: endpoint), scope: scope(), topic: topic()))
        }
    }

    func testConfirmedLambdaSubscriptionCanHaveCrossAccountOwner() throws {
        let subscription = subscription(owner: "444455556666", endpoint: lambdaARN(qualifier: "production"))
        let target = try XCTUnwrap(SNSRelationshipMapping.lambdaTarget(subscription, scope: scope(), topic: topic()))

        XCTAssertEqual(target.resourceID, "private-handler")
        XCTAssertEqual(target.qualifier, "production")
        XCTAssertEqual(target.scope.accountID, "111122223333")
        XCTAssertTrue(SNSRelationshipMapping.navigationNote(subscription, scope: scope(), topic: topic()).contains("alias or version"))
    }

    func testOnlyConfirmedLambdaProtocolCanNavigate() {
        for status in ["Pending confirmation", "Deleted", "Unknown", "", "confirmed"] {
            XCTAssertNil(SNSRelationshipMapping.lambdaTarget(subscription(status: status), scope: scope(), topic: topic()))
        }
        for protocolName in ["sqs", "email", "https", "http", "application", "Lambda", ""] {
            XCTAssertNil(SNSRelationshipMapping.lambdaTarget(subscription(protocolName: protocolName), scope: scope(), topic: topic()))
        }
        let omitted = SNSSubscription(id: "omitted", arn: topic().arn + ":confirmed-1", endpoint: lambdaARN(),
                                      topicARN: topic().arn, status: "Confirmed")
        XCTAssertNil(SNSRelationshipMapping.lambdaTarget(omitted, scope: scope(), topic: topic()))
    }

    func testClaimedConfirmedStatusCannotBypassSubscriptionARNOrTopicChecks() {
        for arn in [
            nil, "", "PendingConfirmation", "Deleted", "future-status", topic().arn, topic().arn + ":",
            topic().arn + ":one:two", topic().arn + ":has spaces", topic().arn + ":identifier\n",
            topic("different").arn + ":confirmed-1",
            "arn:aws:sns:eu-west-1:111122223333:alerts:confirmed-1",
            "arn:aws:sns:us-east-1:999988887777:alerts:confirmed-1"
        ] as [String?] {
            let row = subscription(arn: arn)
            XCTAssertNil(SNSRelationshipMapping.lambdaTarget(row, scope: scope(), topic: topic()))
        }
        let wrongTopic = SNSSubscription(id: "wrong-topic", arn: topic().arn + ":confirmed-1",
                                         protocolName: "lambda", endpoint: lambdaARN(),
                                         topicARN: topic("different").arn, status: "Confirmed")
        XCTAssertNil(SNSRelationshipMapping.lambdaTarget(wrongTopic, scope: scope(), topic: topic()))
        XCTAssertNil(SNSRelationshipMapping.lambdaTarget(subscription(endpoint: nil), scope: scope(), topic: topic()))
    }

    func testNavigationNotesDoNotLeakEndpointsOrQualifiers() {
        let privateEndpoint = lambdaARN(qualifier: "private-release")
        let rows = [
            subscription(endpoint: privateEndpoint),
            subscription(status: "Pending confirmation", endpoint: privateEndpoint),
            subscription(status: "Deleted", endpoint: privateEndpoint),
            subscription(status: "Unknown", endpoint: privateEndpoint),
            subscription(protocolName: "https", endpoint: "https://private.example.invalid/token"),
            subscription(endpoint: lambdaARN(account: "999988887777", qualifier: "private-release")),
            subscription(endpoint: "malformed-private-endpoint"),
            subscription(arn: "PendingConfirmation", endpoint: privateEndpoint),
            subscription(endpoint: nil)
        ]
        for row in rows {
            let note = SNSRelationshipMapping.navigationNote(row, scope: scope(), topic: topic())
            XCTAssertFalse(note.isEmpty)
            XCTAssertFalse(note.contains("private-handler"))
            XCTAssertFalse(note.contains("private-release"))
            XCTAssertFalse(note.contains("private.example.invalid"))
            XCTAssertFalse(note.contains("malformed-private-endpoint"))
            XCTAssertFalse(note.contains("999988887777"))
            if let endpoint = row.endpoint { XCTAssertFalse(note.contains(endpoint)) }
        }
        let crossRegion = SNSRelationshipMapping.navigationNote(
            subscription(endpoint: lambdaARN(region: "eu-west-1")), scope: scope(), topic: topic()
        )
        XCTAssertTrue(crossRegion.contains("matching profile and region"))
    }

    func testAlarmScopeConversionPreservesProfileIdentityRegionAndConfigurationPaths() {
        let original = scope(profileName: "custom", profileRole: "ReadOnly", session: "company",
                             configPath: "/example/sso/config", credentialsPath: "/example/sso/credentials")
        let converted = original.alarmScope

        XCTAssertEqual(converted.profile, original.profile)
        XCTAssertEqual(converted.profileName, original.profileName)
        XCTAssertEqual(converted.accountID, original.accountID)
        XCTAssertEqual(converted.principalARN, original.principalARN)
        XCTAssertEqual(converted.region, original.region)
        XCTAssertEqual(converted.configPath, original.configPath)
        XCTAssertEqual(converted.credentialsPath, original.credentialsPath)
    }

    func testChinaAndGovCloudRelatedResourcesRemainWithinTheirPartition() throws {
        for (partition, region) in [("aws-cn", "cn-north-1"), ("aws-us-gov", "us-gov-west-1")] {
            let regionalScope = scope(region: region, principal: "arn:\(partition):sts::111122223333:assumed-role/Test/session")
            let targetARN = "arn:\(partition):lambda:\(region):111122223333:function:private-handler:production"
            let target = try XCTUnwrap(SNSRelatedResource(scope: regionalScope, service: .lambda, arn: targetARN))

            XCTAssertTrue(target.isValid(in: regionalScope))
            XCTAssertFalse(target.isValid(in: scope()))
            XCTAssertEqual(target.qualifier, "production")
        }
    }

    private func topic(_ name: String = "alerts") -> SNSTopic {
        SNSTopic(arn: "arn:aws:sns:us-east-1:111122223333:\(name)", name: name)
    }

    private func alarmARN(_ name: String, region: String = "us-east-1") -> String {
        "arn:aws:cloudwatch:\(region):111122223333:alarm:\(name)"
    }

    private func alarm(
        _ name: String, alarmActions: [String] = [], okActions: [String] = [], insufficientDataActions: [String] = []
    ) -> CloudWatchAlarm {
        CloudWatchAlarm(arn: alarmARN(name), name: name, kind: .metric, state: "OK",
                        alarmActions: alarmActions, okActions: okActions, insufficientDataActions: insufficientDataActions)
    }

    private func lambdaARN(
        name: String = "private-handler", account: String = "111122223333",
        region: String = "us-east-1", qualifier: String? = nil
    ) -> String {
        "arn:aws:lambda:\(region):\(account):function:\(name)" + (qualifier.map { ":\($0)" } ?? "")
    }

    private func subscription(
        arn: String? = "arn:aws:sns:us-east-1:111122223333:alerts:confirmed-1",
        protocolName: String = "lambda", status: String = "Confirmed", owner: String = "111122223333",
        endpoint: String? = "arn:aws:lambda:us-east-1:111122223333:function:private-handler"
    ) -> SNSSubscription {
        SNSSubscription(id: "subscription", arn: arn, protocolName: protocolName, endpoint: endpoint,
                        owner: owner, topicARN: topic().arn, status: status)
    }

    private func scope(
        profileName: String = "work", profileRole: String = "ReadOnlyAccess", session: String = "company",
        profileRegion: String = "us-east-1", account: String = "111122223333", region: String = "us-east-1",
        principal: String? = nil, configPath: String = "/example/config", credentialsPath: String = "/example/credentials"
    ) -> SNSScope {
        SNSScope(
            profile: AWSProfile(name: profileName, region: profileRegion, ssoStartURL: nil, ssoRegion: nil,
                                ssoAccountID: account, ssoRoleName: profileRole, ssoSessionName: session),
            identity: AWSIdentity(account: account, arn: principal ?? "arn:aws:sts::\(account):assumed-role/Test/session", userID: "example"),
            region: region,
            paths: AWSConfigurationPaths(environment: ["AWS_CONFIG_FILE": configPath, "AWS_SHARED_CREDENTIALS_FILE": credentialsPath])
        )
    }
}
