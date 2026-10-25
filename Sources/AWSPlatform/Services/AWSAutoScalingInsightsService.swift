import Foundation
import SotoCore
import SotoEC2
import SotoAutoScaling

struct AWSAutoScalingInsightsService: Sendable {
    typealias TemplateLoader = @Sendable (EC2.DescribeLaunchTemplateVersionsRequest) async throws -> EC2.DescribeLaunchTemplateVersionsResult
    typealias RefreshLoader = @Sendable (AutoScaling.DescribeInstanceRefreshesType) async throws -> AutoScaling.DescribeInstanceRefreshesAnswer

    private let provider: AWSServiceProvider?
    private let templateLoader: TemplateLoader?
    private let refreshLoader: RefreshLoader?

    init(provider: AWSServiceProvider) { self.provider = provider; templateLoader = nil; refreshLoader = nil }

    init(templateLoader: @escaping TemplateLoader, refreshLoader: @escaping RefreshLoader) {
        provider = nil; self.templateLoader = templateLoader; self.refreshLoader = refreshLoader
    }

    func loadTemplateVersions(scope: MonitoringScope, group: ASGGroup, template: ASGLaunchTemplate) async throws -> [ASGTemplateVersion] {
        do {
            try ASGInsightsContext.validate(scope: scope, group: group)
            guard ASGInsightsContext.templates(in: group).contains(template) else { throw AutoScalingInsightsError.invalidTemplate }
            try Self.validateTemplate(template)
            let load: TemplateLoader
            if let templateLoader { load = templateLoader }
            else {
                guard let provider else { throw AutoScalingInsightsError.invalidScope }
                let client = try await provider.ec2Client(scope: scope)
                load = { try await client.describeLaunchTemplateVersions($0) }
            }
            let rows: [ASGTemplateVersion] = try await Self.pages { token in
                let response = try await load(.init(launchTemplateId: template.templateID,
                    launchTemplateName: template.templateID == nil ? template.name : nil, maxResults: 100,
                    nextToken: token, resolveAlias: false, versions: [template.version!]))
                try Task.checkCancellation()
                return (try (response.launchTemplateVersions ?? []).map { try Self.map($0, reference: template, scope: scope) }, response.nextToken)
            }
            guard Set(rows.map(\.id)).count == rows.count, rows.count <= 1 else { throw AutoScalingInsightsError.invalidResponse }
            return rows
        } catch { throw Self.safe(error, templates: true) }
    }

    func loadInstanceRefreshes(scope: MonitoringScope, group: ASGGroup, now: Date = Date()) async throws -> [ASGInstanceRefresh] {
        do {
            try ASGInsightsContext.validate(scope: scope, group: group)
            let load: RefreshLoader
            if let refreshLoader { load = refreshLoader }
            else {
                guard let provider else { throw AutoScalingInsightsError.invalidScope }
                let client = try await provider.autoScalingClient(scope: scope)
                load = { try await client.describeInstanceRefreshes($0) }
            }
            let rows: [ASGInstanceRefresh] = try await Self.pages { token in
                let response = try await load(.init(autoScalingGroupName: group.name, maxRecords: 100, nextToken: token))
                try Task.checkCancellation()
                return (try (response.instanceRefreshes ?? []).map { raw in
                    guard raw.autoScalingGroupName == group.name, let id = raw.instanceRefreshId,
                          !id.isEmpty, !id.contains(where: \.isWhitespace),
                          raw.percentageComplete.map({ (0...100).contains($0) }) ?? true,
                          raw.instancesToUpdate.map({ $0 >= 0 }) ?? true else { throw AutoScalingInsightsError.invalidResponse }
                    return ASGInstanceRefresh(id: id, groupName: group.name, status: raw.status?.rawValue,
                        percentageComplete: raw.percentageComplete, instancesRemaining: raw.instancesToUpdate,
                        startedAt: raw.startTime, endedAt: raw.endTime, statusReason: raw.statusReason, strategy: raw.strategy?.rawValue)
                }, response.nextToken)
            }
            guard Set(rows.map(\.id)).count == rows.count else { throw AutoScalingInsightsError.invalidResponse }
            let start = now.addingTimeInterval(-42 * 24 * 60 * 60)
            return rows.filter { $0.startedAt.map { $0 >= start } ?? true }
        } catch { throw Self.safe(error, templates: false) }
    }

    static func validateTemplate(_ reference: ASGLaunchTemplate) throws {
        if let id = reference.templateID {
            guard id.range(of: "^lt-(?:[0-9a-f]{8}|[0-9a-f]{17})$", options: .regularExpression) != nil else {
                throw AutoScalingInsightsError.invalidTemplate
            }
        } else {
            guard let name = reference.name, (3...128).contains(name.count),
                  name.range(of: "^[a-zA-Z0-9()./_-]+$", options: .regularExpression) != nil else {
                throw AutoScalingInsightsError.invalidTemplate
            }
        }
        guard let version = reference.version,
              version == "$Latest" || version == "$Default" ||
                (version.range(of: "^[0-9]+$", options: .regularExpression) != nil && (Int64(version) ?? 0) > 0)
        else { throw AutoScalingInsightsError.invalidTemplate }
    }

    private static func map(_ raw: EC2.LaunchTemplateVersion, reference: ASGLaunchTemplate, scope: MonitoringScope) throws -> ASGTemplateVersion {
        guard let id = raw.launchTemplateId,
              id.range(of: "^lt-(?:[0-9a-f]{8}|[0-9a-f]{17})$", options: .regularExpression) != nil,
              let version = raw.versionNumber, version > 0,
              reference.templateID.map({ $0 == id }) ?? (raw.launchTemplateName == reference.name),
              reference.name.map({ raw.launchTemplateName == nil || raw.launchTemplateName == $0 }) ?? true,
              Int64(reference.version ?? "").map({ $0 == version }) ?? true,
              reference.version != "$Default" || raw.defaultVersion != false else { throw AutoScalingInsightsError.invalidResponse }
        if let creator = raw.createdBy {
            let parts = creator.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
            let partition = scope.principalARN.split(separator: ":", omittingEmptySubsequences: false)[1]
            guard parts.count == 6, parts[0] == "arn", parts[1] == partition, ["iam", "sts"].contains(String(parts[2])),
                  parts[3].isEmpty, parts[4] == scope.accountID, !parts[5].isEmpty,
                  !creator.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw AutoScalingInsightsError.invalidResponse
            }
        }
        let data = raw.launchTemplateData
        return ASGTemplateVersion(reference: reference, templateID: id, templateName: raw.launchTemplateName,
            version: version, isDefault: raw.defaultVersion, description: raw.versionDescription,
            createdAt: raw.createTime, createdBy: raw.createdBy, imageID: data?.imageId,
            instanceType: data?.instanceType?.rawValue, keyName: data?.keyName, securityGroupIDs: data?.securityGroupIds,
            instanceProfileARN: data?.iamInstanceProfile?.arn, instanceProfileName: data?.iamInstanceProfile?.name,
            ebsOptimized: data?.ebsOptimized, detailedMonitoring: data?.monitoring?.enabled)
    }

    private static func pages<Value: Sendable>(_ load: @Sendable (String?) async throws -> ([Value], String?)) async throws -> [Value] {
        var result: [Value] = [], token: String?, seen: Set<String> = []
        for _ in 0..<1_000 {
            try Task.checkCancellation()
            let (page, next) = try await load(token)
            try Task.checkCancellation()
            result += page
            guard let next, !next.isEmpty else { return result }
            guard !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, seen.insert(next).inserted else {
                throw AutoScalingInsightsError.incompletePagination
            }
            token = next
        }
        throw AutoScalingInsightsError.incompletePagination
    }

    private static func safe(_ error: Error, templates: Bool) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if error is AutoScalingInsightsError { return error }
        if error is AWSServiceError { return AutoScalingInsightsError.invalidScope }
        let code = (error as? AWSResponseError)?.errorCode ?? (error as? AWSErrorType)?.errorCode ?? ""
        if ["AccessDenied", "AccessDeniedException", "UnauthorizedOperation", "UnauthorizedException", "ForbiddenException"].contains(code) {
            return templates ? AutoScalingInsightsError.templatesPermission : AutoScalingInsightsError.refreshesPermission
        }
        if UserFacingError.requiresSSOLogin(error) { return AutoScalingInsightsError.credentials }
        if error is URLError { return AutoScalingInsightsError.network }
        switch code {
        case "Throttling", "ThrottlingException", "TooManyRequestsException", "RequestLimitExceeded": return AutoScalingInsightsError.throttled
        case "InvalidNextToken", "InvalidNextTokenException", "InvalidPaginationToken": return AutoScalingInsightsError.incompletePagination
        default: return AutoScalingInsightsError.failed
        }
    }
}
