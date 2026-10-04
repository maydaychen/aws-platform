import Foundation

extension MonitoringScope {
    var route53Scope: Route53Scope {
        Route53Scope(profile: profile, identity: AWSIdentity(account: accountID, arn: principalARN, userID: ""), paths: paths)
    }

    func replacingRegion(_ region: String) -> MonitoringScope {
        MonitoringScope(profile: profile, identity: AWSIdentity(account: accountID, arn: principalARN, userID: ""), region: region, paths: paths)
    }

    func sharesIdentity(with other: MonitoringScope) -> Bool {
        profile == other.profile && accountID == other.accountID && principalARN == other.principalARN && paths == other.paths
    }
}

struct ResourceRelationReference: Hashable, Sendable {
    let scope: MonitoringScope
    let service: AWSService
    let resourceID: String
    let name: String
    var recordID: Route53Record.ID? = nil

    var isValid: Bool {
        guard scope.isValid, !scope.configPath.isEmpty, !scope.credentialsPath.isEmpty, !name.isEmpty else { return false }
        switch service {
        case .ec2, .loadBalancers, .targetGroups, .lambda:
            return recordID == nil && ELBResourceReference(scope: scope, service: service, resourceID: resourceID, name: name) != nil
        case .securityGroups: return recordID == nil && SecurityGroupModel.validID(resourceID)
        case .route53:
            guard (try? scope.route53Scope.partition()) != nil,
                  Route53HostedZone.normalizedID(resourceID) == resourceID else { return false }
            return recordID.map { !$0.name.isEmpty && !$0.type.isEmpty && $0.setIdentifier != "" } ?? true
        default: return false
        }
    }

    var canExplore: Bool { isValid && service != .lambda }
    var isGlobal: Bool { service == .route53 }
    var canScanReverse: Bool { [.ec2, .loadBalancers, .securityGroups].contains(service) }

    func replacingRegion(_ region: String) -> Self {
        Self(scope: scope.replacingRegion(region), service: service, resourceID: resourceID, name: name, recordID: recordID)
    }

    var favoriteDestination: ResourceFavorite {
        let id = service == .lambda ? resourceID.split(separator: ":").dropFirst(6).first.map(String.init) ?? "" : resourceID
        return ResourceFavorite(profileName: scope.profile.name, accountID: scope.accountID,
                                region: isGlobal ? "global" : scope.region, service: service,
                                resourceID: id, displayName: name)
    }
}

struct ResourceRelationNode: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let relation: String
    var reference: ResourceRelationReference? = nil
    var fields: [ELBField] = []
    var note: String? = nil
}

struct ResourceRelationSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var nodes: [ResourceRelationNode] = []
    var error: String? = nil
    var note: String? = nil
    var isIncomplete: Bool = false
    var requiresScan: Bool = false
    var checkedCount: Int? = nil
    var totalCount: Int? = nil
    var resourceFailures: [ResourceRelationFailure] = []
}

/// Keep AWS names separate from app-owned messages for display localization.
struct ResourceRelationFailure: Equatable, Sendable {
    let resourceName: String
    let resourceID: String
    let message: String
}

struct ResourceRelationResult: Equatable, Sendable {
    let reference: ResourceRelationReference
    var sections: [ResourceRelationSection] = []
}

enum ResourceRelationError: LocalizedError, Equatable {
    case invalidScope, invalidResource, notFound, failed
    var errorDescription: String? {
        switch self {
        case .invalidScope: return "The selected profile, account or query region changed. Open relationships again in the current scope."
        case .invalidResource: return "The relationship contains incomplete or mismatched resource information."
        case .notFound: return "This resource was not found in the selected profile and region. It may have been removed or be inaccessible."
        case .failed: return "The relationship query failed. Check this profile's permissions and retry."
        }
    }
}
