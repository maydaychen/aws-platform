import Combine
import Foundation

/// A window's pending destination is separate from the app-wide saved list.
@MainActor
final class FavoriteNavigation: ObservableObject {
    enum Source {
        case favorite, recent, relationship

        var noun: String {
            switch self {
            case .favorite: return "favorite"
            case .recent: return "recent resource"
            case .relationship: return "related resource"
            }
        }
        var listName: String {
            switch self {
            case .favorite: return "Favorites"
            case .recent: return "Recent"
            case .relationship: return "Relationships"
            }
        }
        var retryMessage: String {
            self == .relationship ? "Open Relationships again to retry." : "The \(noun) is still saved."
        }
    }

    @Published private(set) var target: ResourceFavorite?
    @Published private(set) var error: String?
    @Published private(set) var relationshipReference: ResourceRelationReference?
    private var source: Source = .favorite
    private var generation = 0

    func begin(_ favorite: ResourceFavorite, profiles: [AWSProfile], selectedProfileName: String?, source: Source = .favorite) -> Bool {
        cancel()
        self.source = source
        guard favorite.isValid else {
            error = "This \(source.noun) has an invalid destination."
            return false
        }
        guard profiles.contains(where: { $0.name == favorite.profileName }) else {
            error = "Profile \(favorite.profileName) is unavailable. Restore its AWS configuration and retry. \(source.retryMessage)"
            return false
        }
        guard selectedProfileName == favorite.profileName else {
            error = "Select profile \(favorite.profileName) in its session first, then open this \(source.noun). No profile was selected automatically."
            return false
        }
        target = favorite
        return true
    }

    func beginRelationship(_ reference: ResourceRelationReference, currentScope: MonitoringScope?,
                           profiles: [AWSProfile]) -> Bool {
        cancel()
        source = .relationship
        guard reference.isValid else {
            error = ResourceRelationError.invalidResource.localizedDescription
            return false
        }
        guard let currentScope, currentScope.isValid,
              currentScope.sharesIdentity(with: reference.scope),
              profiles.contains(reference.scope.profile) else {
            error = "Select and verify the relationship's profile and account first. No profile was selected automatically."
            return false
        }
        let destination = reference.isGlobal ? reference.replacingRegion(currentScope.region) : reference
        relationshipReference = destination
        target = destination.favoriteDestination
        return true
    }

    @discardableResult
    func validateRelationshipScope(_ scope: MonitoringScope?) -> Bool {
        guard let relationshipReference else { return false }
        guard relationshipReference.isValid, scope == relationshipReference.scope else {
            fail(ResourceRelationError.invalidScope.localizedDescription)
            return false
        }
        return true
    }

    func matches(profileName: String?, region: String) -> Bool {
        guard let target else { return true }
        if let relationshipReference {
            return target.profileName == profileName && relationshipReference.scope.region == region
        }
        return target.profileName == profileName && (target.service == .route53 || target.region == region)
    }

    func verifyAccount(_ accountID: String) -> Bool {
        guard let target else { return false }
        guard target.accountID == accountID else {
            fail("Profile \(target.profileName) now resolves to account \(accountID), but this \(source.noun) belongs to \(target.accountID). It was not opened.")
            return false
        }
        return true
    }

    func finish(found: Bool, loadError: String?) {
        guard let target else { return }
        if let loadError {
            fail("Unable to open \(target.displayName): \(loadError) \(source.retryMessage)")
        } else if !found {
            let location = target.service == .route53 ? "profile" : "profile and region"
            let context = source == .relationship ? "selected" : "saved"
            fail("\(target.displayName) was not found in the \(context) \(location). It may have been removed or be inaccessible. \(source.retryMessage)")
        } else {
            cancel()
        }
    }

    func resolve(ec2: EC2ViewModel, lambda: LambdaViewModel, s3: S3ViewModel, alarms: AlarmViewModel, sns: SNSViewModel,
                 route53: Route53ViewModel? = nil, elb: ELBViewModel? = nil,
                 securityGroups: SecurityGroupsViewModel? = nil) {
        guard let target, source != .relationship else { return }
        switch target.service {
        case .ec2:
            ec2.searchText = ""
            ec2.stateFilter = "All"
            ec2.healthFilter = .all
            ec2.selectedInstance = ec2.instances.first { $0.instanceId == target.resourceID }
            finish(found: ec2.selectedInstance != nil, loadError: ec2.error)
        case .lambda:
            lambda.searchText = ""
            lambda.stateFilter = "All"
            lambda.packageFilter = "All"
            lambda.selectedFunction = lambda.functions.first { $0.functionName == target.resourceID }
            finish(found: lambda.selectedFunction != nil, loadError: lambda.error)
        case .s3:
            s3.bucketSearchText = ""
            s3.objectSearchText = ""
            let bucket = s3.buckets.first { $0.name == target.resourceID }
            if let bucket {
                s3.selectBucket(bucket)
            } else {
                s3.selectedBucket = nil
            }
            finish(found: bucket != nil, loadError: s3.error)
        case .alarms:
            alarms.searchText = ""
            alarms.stateFilter = "All"
            alarms.kindFilter = nil
            alarms.selectedAlarm = alarms.alarms.first { $0.arn == target.resourceID }
            finish(found: alarms.selectedAlarm != nil, loadError: alarms.error)
        case .sns:
            sns.searchText = ""
            sns.kindFilter = nil
            sns.selectedTopic = sns.topics.first { $0.arn == target.resourceID }
            finish(found: sns.selectedTopic != nil, loadError: sns.error)
        case .route53:
            route53?.searchText = ""
            route53?.privateFilter = nil
            guard let route53, route53.error == nil else {
                route53?.selectedZone = nil
                finish(found: false, loadError: route53?.error)
                return
            }
            route53.selectedZone = route53.zones.first { $0.id == target.resourceID }
            finish(found: route53.selectedZone != nil, loadError: nil)
        case .loadBalancers:
            elb?.searchText = ""
            elb?.kindFilter = "All"
            guard let elb, elb.loadBalancersError == nil, !elb.isLoadBalancersStale else {
                elb?.selectedLoadBalancer = nil
                finish(found: false, loadError: elb?.loadBalancersError)
                return
            }
            elb.selectedLoadBalancer = elb.loadBalancers.first { $0.arn == target.resourceID }
            finish(found: elb.selectedLoadBalancer != nil, loadError: nil)
        case .targetGroups:
            elb?.groupSearchText = ""
            elb?.targetTypeFilter = "All"
            guard let elb, elb.targetGroupsError == nil, !elb.isTargetGroupsStale else {
                elb?.selectedTargetGroup = nil
                finish(found: false, loadError: elb?.targetGroupsError)
                return
            }
            elb.selectedTargetGroup = elb.targetGroups.first { $0.arn == target.resourceID }
            finish(found: elb.selectedTargetGroup != nil, loadError: nil)
        case .securityGroups:
            securityGroups?.searchText = ""
            securityGroups?.vpcFilter = "All"
            guard let securityGroups, securityGroups.error == nil, !securityGroups.isStale, !securityGroups.isLoading else {
                securityGroups?.selectedGroup = nil
                finish(found: false, loadError: securityGroups?.error)
                return
            }
            securityGroups.selectedGroup = securityGroups.groups.first { $0.id == target.resourceID }
            finish(found: securityGroups.selectedGroup != nil, loadError: nil)
        }
    }

    func resolveRelationship(ec2: EC2ViewModel, lambda: LambdaViewModel, s3: S3ViewModel,
                             alarms: AlarmViewModel, sns: SNSViewModel, route53: Route53ViewModel? = nil,
                             elb: ELBViewModel? = nil, securityGroups: SecurityGroupsViewModel? = nil,
                             latestScope: @MainActor () -> MonitoringScope?) async {
        guard let reference = relationshipReference else { return }
        let request = generation
        guard isCurrentRelationship(reference, request: request), validateRelationshipScope(latestScope()) else { return }

        switch reference.service {
        case .ec2:
            ec2.selectedInstance = nil
            guard ec2.error == nil, !ec2.isLoading else {
                finish(found: false, loadError: ec2.error ?? "The instance list is still loading.")
                return
            }
            ec2.searchText = ""
            ec2.stateFilter = "All"
            ec2.healthFilter = .all
            ec2.selectedInstance = ec2.instances.first { $0.instanceId == reference.resourceID }
            finish(found: ec2.selectedInstance != nil, loadError: nil)
        case .lambda:
            lambda.selectedFunction = nil
            guard lambda.error == nil, !lambda.isLoading else {
                finish(found: false, loadError: lambda.error ?? "The function list is still loading.")
                return
            }
            let baseARN = reference.resourceID.split(separator: ":").prefix(7).joined(separator: ":")
            lambda.searchText = ""
            lambda.stateFilter = "All"
            lambda.packageFilter = "All"
            lambda.selectedFunction = lambda.functions.first {
                $0.arn == baseARN && $0.functionName == reference.favoriteDestination.resourceID
            }
            finish(found: lambda.selectedFunction != nil, loadError: nil)
        case .loadBalancers, .targetGroups:
            guard let elb, elb.scope == reference.scope else {
                fail(ResourceRelationError.invalidScope.localizedDescription)
                return
            }
            if reference.service == .loadBalancers {
                elb.selectedLoadBalancer = nil
                guard elb.loadBalancersError == nil, !elb.isLoadBalancersStale, !elb.isLoadBalancersLoading else {
                    finish(found: false, loadError: elb.loadBalancersError ?? "Refresh the related load balancer list and retry.")
                    return
                }
                elb.searchText = ""
                elb.kindFilter = "All"
                elb.selectedLoadBalancer = elb.loadBalancers.first { $0.arn == reference.resourceID }
                finish(found: elb.selectedLoadBalancer != nil, loadError: nil)
            } else {
                elb.selectedTargetGroup = nil
                guard elb.targetGroupsError == nil, !elb.isTargetGroupsStale, !elb.isTargetGroupsLoading else {
                    finish(found: false, loadError: elb.targetGroupsError ?? "Refresh the related target group list and retry.")
                    return
                }
                elb.groupSearchText = ""
                elb.targetTypeFilter = "All"
                elb.selectedTargetGroup = elb.targetGroups.first { $0.arn == reference.resourceID }
                finish(found: elb.selectedTargetGroup != nil, loadError: nil)
            }
        case .securityGroups:
            guard let securityGroups, securityGroups.scope == reference.scope else {
                fail(ResourceRelationError.invalidScope.localizedDescription)
                return
            }
            securityGroups.selectedGroup = nil
            guard securityGroups.error == nil, !securityGroups.isStale, !securityGroups.isLoading else {
                finish(found: false, loadError: securityGroups.error ?? "Refresh the related security group list and retry.")
                return
            }
            guard let group = securityGroups.groups.first(where: { $0.id == reference.resourceID }) else {
                finish(found: false, loadError: nil)
                return
            }
            guard group.ownerID == reference.scope.accountID else {
                fail("This security group's owner could not be verified as the selected account. Open it directly from the Security Groups list to inspect shared ownership.")
                return
            }
            securityGroups.searchText = ""
            securityGroups.vpcFilter = "All"
            securityGroups.selectedGroup = group
            finish(found: true, loadError: nil)
        case .route53:
            guard let route53, route53.scope == reference.scope.route53Scope else {
                fail(ResourceRelationError.invalidScope.localizedDescription)
                return
            }
            guard route53.error == nil, !route53.isListStale, !route53.isLoading else {
                route53.selectedZone = nil
                finish(found: false, loadError: route53.error ?? "Refresh the hosted zone list and retry.")
                return
            }
            route53.searchText = ""
            route53.privateFilter = nil
            guard let zone = route53.zones.first(where: { $0.id == reference.resourceID }) else {
                route53.selectedZone = nil
                finish(found: false, loadError: nil)
                return
            }
            route53.selectedZone = zone
            guard let recordID = reference.recordID else {
                finish(found: true, loadError: nil)
                return
            }
            await route53.waitForDetails()
            guard isCurrentRelationship(reference, request: request), validateRelationshipScope(latestScope()) else { return }
            guard route53.scope == reference.scope.route53Scope, route53.selectedZone?.id == zone.id else {
                fail("The selected hosted zone changed before the related record could be opened. Open Relationships again to retry.")
                return
            }
            guard route53.error == nil, !route53.isListStale, !route53.isLoading,
                  route53.recordsError == nil, !route53.isRecordsLoading else {
                finish(found: false, loadError: route53.recordsError ?? route53.error ?? "The record list is not ready. Refresh and retry.")
                return
            }
            if route53.focusRecord(recordID) {
                finish(found: true, loadError: nil)
            } else {
                fail("The exact related record was not found in this hosted zone. Its name, type or routing identifier may have changed. Open Relationships again to retry.")
            }
        default:
            fail(ResourceRelationError.invalidResource.localizedDescription)
        }
    }

    private func isCurrentRelationship(_ reference: ResourceRelationReference, request: Int) -> Bool {
        guard generation == request, relationshipReference == reference else { return false }
        guard !Task.isCancelled else {
            cancel()
            return false
        }
        return true
    }

    func failConnection() {
        fail("The \(source.noun) could not be opened. Resolve the connection error, then open it again from \(source.listName).")
    }

    func fail(_ message: String) {
        generation += 1
        target = nil
        relationshipReference = nil
        error = message
    }

    func cancel() {
        generation += 1
        target = nil
        relationshipReference = nil
        error = nil
    }
}
