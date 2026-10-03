import Foundation
import SotoCore

struct SNSRelatedResource: Hashable, Sendable {
    let scope: SNSScope
    let service: AWSService
    let arn: String
    let resourceID: String
    let qualifier: String?

    init?(scope: SNSScope, service: AWSService, arn: String) {
        guard let parsed = SNSRelationshipARN.parse(arn), parsed.matches(scope) else { return nil }
        switch service {
        case .alarms:
            guard parsed.service == "cloudwatch", parsed.resource.hasPrefix("alarm:"),
                  !parsed.resource.dropFirst("alarm:".count).isEmpty else { return nil }
            resourceID = arn
            qualifier = nil
        case .lambda:
            guard parsed.service == "lambda", let function = parsed.lambdaFunction else { return nil }
            resourceID = function.name
            qualifier = function.qualifier
        case .sns:
            guard parsed.service == "sns", parsed.resource.count <= 256,
                  parsed.resource.range(of: "^[A-Za-z0-9_-]+(?:\\.fifo)?$", options: .regularExpression) != nil
            else { return nil }
            resourceID = arn
            qualifier = nil
        default:
            return nil
        }
        self.scope = scope
        self.service = service
        self.arn = arn
    }

    func isValid(in scope: SNSScope?) -> Bool {
        guard let scope, scope == self.scope else { return false }
        return SNSRelatedResource(scope: scope, service: service, arn: arn) == self
    }
}

struct SNSAlarmRelationship: Identifiable, Hashable, Sendable {
    let alarm: CloudWatchAlarm
    let triggers: [String]
    let target: SNSRelatedResource

    var id: String { alarm.arn }
}

enum SNSRelationshipMapping {
    static func alarmSources(_ alarms: [CloudWatchAlarm], topic: SNSTopic, scope: SNSScope) -> [SNSAlarmRelationship] {
        guard SNSRelationshipARN.validTopic(topic, scope: scope) else { return [] }
        let triggerOrder = ["ALARM", "OK", "INSUFFICIENT_DATA"]
        var relationships: [String: SNSAlarmRelationship] = [:]
        for alarm in alarms {
            guard let target = SNSRelatedResource(scope: scope, service: .alarms, arn: alarm.arn),
                  let parsed = SNSRelationshipARN.parse(alarm.arn),
                  parsed.resource == "alarm:\(alarm.name)", !alarm.name.isEmpty else { continue }
            let matched = [
                ("ALARM", alarm.alarmActions), ("OK", alarm.okActions),
                ("INSUFFICIENT_DATA", alarm.insufficientDataActions)
            ].compactMap { trigger, actions in actions.contains(topic.arn) ? trigger : nil }
            guard !matched.isEmpty else { continue }
            let previous = relationships[alarm.arn]
            let triggers = Set((previous?.triggers ?? []) + matched)
            relationships[alarm.arn] = SNSAlarmRelationship(
                alarm: previous?.alarm ?? alarm,
                triggers: triggerOrder.filter { triggers.contains($0) },
                target: target
            )
        }
        return relationships.values.sorted {
            $0.alarm.name == $1.alarm.name ? $0.id < $1.id : $0.alarm.name < $1.alarm.name
        }
    }

    static func lambdaTarget(_ subscription: SNSSubscription, scope: SNSScope, topic: SNSTopic) -> SNSRelatedResource? {
        guard subscription.protocolName == "lambda", subscription.status == "Confirmed",
              SNSRelationshipARN.validSubscription(subscription, topic: topic, scope: scope),
              let endpoint = subscription.endpoint else { return nil }
        return SNSRelatedResource(scope: scope, service: .lambda, arn: endpoint)
    }

    static func navigationNote(_ subscription: SNSSubscription, scope: SNSScope, topic: SNSTopic) -> String {
        guard SNSRelationshipARN.validTopic(topic, scope: scope), subscription.topicARN == topic.arn else {
            return "This subscription does not match the selected topic and account context."
        }
        switch subscription.status {
        case "Pending confirmation":
            return "Waiting for subscription confirmation. Resource navigation is unavailable."
        case "Deleted":
            return "This subscription is deleted. Resource navigation is unavailable."
        case "Confirmed":
            break
        default:
            return "The subscription state is unknown. Resource navigation is unavailable."
        }
        guard SNSRelationshipARN.validSubscription(subscription, topic: topic, scope: scope) else {
            return "The subscription ARN does not match the selected topic. Resource navigation is unavailable."
        }
        guard subscription.protocolName == "lambda" else {
            return "Resource navigation is currently available only for Lambda subscriptions."
        }
        guard let endpoint = subscription.endpoint else {
            return "The Lambda endpoint was not returned."
        }
        guard let parsed = SNSRelationshipARN.parse(endpoint), parsed.service == "lambda", parsed.lambdaFunction != nil else {
            return "The Lambda endpoint ARN is invalid or unsupported."
        }
        guard let target = lambdaTarget(subscription, scope: scope, topic: topic) else {
            return "This Lambda target belongs to another account, region or AWS partition. Select the matching profile and region first."
        }
        if target.qualifier != nil {
            return "Qualified Lambda target. Opens the function overview, not the specific alias or version."
        }
        return "Opens the Lambda function overview in the current profile and region."
    }
}

extension SNSScope {
    var alarmScope: AlarmScope {
        AlarmScope(
            profile: profile,
            identity: AWSIdentity(account: accountID, arn: principalARN, userID: ""),
            region: region,
            paths: AWSConfigurationPaths(environment: [
                "AWS_CONFIG_FILE": configPath, "AWS_SHARED_CREDENTIALS_FILE": credentialsPath
            ])
        )
    }
}

private struct SNSRelationshipARN {
    let partition: String
    let service: String
    let region: String
    let account: String
    let resource: String

    private static let partitions: [String: AWSPartition] = [
        "aws": .aws, "aws-cn": .awscn, "aws-us-gov": .awsusgov,
        "aws-iso": .awsiso, "aws-iso-b": .awsisob, "aws-iso-e": .awsisoe,
        "aws-iso-f": .awsisof, "aws-eusc": .awseusc
    ]

    static func parse(_ arn: String) -> Self? {
        let parts = arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == "arn", let partition = partitions[String(parts[1])],
              !parts[2].isEmpty, parts[3].range(of: "^[a-z]{2,4}(?:-[a-z0-9]+)+-[0-9]+$", options: .regularExpression) != nil,
              Region(rawValue: String(parts[3])).partition == partition,
              parts[4].range(of: "^[0-9]{12}$", options: .regularExpression) != nil, !parts[5].isEmpty,
              !arn.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return Self(partition: String(parts[1]), service: String(parts[2]), region: String(parts[3]),
                    account: String(parts[4]), resource: String(parts[5]))
    }

    func matches(_ scope: SNSScope) -> Bool {
        let identity = scope.principalARN.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard !scope.profileName.isEmpty, identity.count == 6, identity[0] == "arn",
              identity[1] == partition, ["sts", "iam"].contains(String(identity[2])),
              identity[4] == scope.accountID, !identity[5].isEmpty else { return false }
        return account == scope.accountID && region == scope.region
    }

    var lambdaFunction: (name: String, qualifier: String?)? {
        let parts = resource.split(separator: ":", omittingEmptySubsequences: false)
        guard service == "lambda", (2...3).contains(parts.count), parts[0] == "function",
              parts[1].range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { return nil }
        let qualifier = parts.count == 3 ? String(parts[2]) : nil
        if let qualifier {
            guard qualifier == "$LATEST" || qualifier.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
                return nil
            }
        }
        return (String(parts[1]), qualifier)
    }

    static func validTopic(_ topic: SNSTopic, scope: SNSScope) -> Bool {
        guard let parsed = parse(topic.arn), parsed.matches(scope), parsed.service == "sns",
              parsed.resource == topic.name,
              topic.name.range(of: "^[A-Za-z0-9_-]+(?:\\.fifo)?$", options: .regularExpression) != nil else { return false }
        return true
    }

    static func validSubscription(_ subscription: SNSSubscription, topic: SNSTopic, scope: SNSScope) -> Bool {
        guard validTopic(topic, scope: scope), subscription.topicARN == topic.arn,
              let arn = subscription.arn, let parsed = parse(arn), parsed.matches(scope), parsed.service == "sns" else { return false }
        let parts = parsed.resource.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0] == topic.name && !parts[1].isEmpty && !parts[1].contains(where: \.isWhitespace)
    }
}
