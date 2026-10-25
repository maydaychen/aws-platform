import SwiftUI

extension ContentView {
    var currentResource: ResourceFavorite? {
        guard case .valid(let identity) = profileVM.profileStatus,
              let profileName = profileVM.selectedProfileID else { return nil }
        let resource: (id: String, name: String)
        switch selectedService {
        case .logs: return nil
        case .codeCommit:
            guard codeCommitVM.scope == currentMonitoringScope, let repository = codeCommitVM.selectedRepository,
                  codeCommitVM.repositories.contains(repository) else { return nil }
            resource = (repository.id, repository.name)
        case .rds:
            guard rdsVM.scope == currentMonitoringScope, let database = rdsVM.selectedDatabase,
                  rdsVM.databases.contains(database) else { return nil }
            resource = (database.arn, database.identifier)
        case .autoScaling:
            guard autoScalingVM.scope == currentMonitoringScope, let group = autoScalingVM.selectedGroup,
                  autoScalingVM.groups.contains(group) else { return nil }
            resource = (group.arn, group.name)
        case .ec2:
            guard let instance = ec2VM.selectedInstance else { return nil }
            resource = (instance.instanceId, instance.name)
        case .lambda:
            guard let function = lambdaVM.selectedFunction else { return nil }
            resource = (function.functionName, function.functionName)
        case .s3:
            guard s3BrowsingBucket == nil, let bucket = s3VM.selectedBucket else { return nil }
            resource = (bucket.name, bucket.name)
        case .alarms:
            guard let alarm = alarmsVM.selectedAlarm else { return nil }
            resource = (alarm.arn, alarm.name)
        case .sns:
            guard let topic = snsVM.selectedTopic else { return nil }
            resource = (topic.arn, topic.name)
        case .route53:
            guard let zone = route53VM.selectedZone, let profile = profileVM.selectedProfile,
                  route53VM.scope == Route53Scope(profile: profile, identity: identity) else { return nil }
            resource = (zone.id, zone.name)
        case .loadBalancers:
            guard elbVM.scope == currentMonitoringScope, let lb = elbVM.selectedLoadBalancer else { return nil }
            resource = (lb.arn, lb.name)
        case .targetGroups:
            guard elbVM.scope == currentMonitoringScope, let group = elbVM.selectedTargetGroup else { return nil }
            resource = (group.arn, group.name)
        case .securityGroups:
            guard securityGroupsVM.scope == currentMonitoringScope, let group = securityGroupsVM.selectedGroup else { return nil }
            resource = (group.id, group.name)
        case .ebsVolumes, .ebsSnapshots:
            let vm = selectedService == .ebsVolumes ? volumesVM : snapshotsVM
            guard vm.scope == currentMonitoringScope, let selected = vm.selectedResource else { return nil }
            resource = (selected.id, selected.name)
        }
        let favorite = ResourceFavorite(
            profileName: profileName, accountID: identity.account,
            region: selectedService == .route53 ? "global" : profileVM.selectedRegion,
            service: selectedService, resourceID: resource.id, displayName: resource.name
        )
        return favorite.isValid ? favorite : nil
    }

    var currentRecentScope: RecentResourceScope? {
        guard profileVM.isProfileReady, let profile = profileVM.selectedProfile,
              case .valid(let identity) = profileVM.profileStatus else { return nil }
        return RecentResourceScope(profileName: profile.name, accountID: identity.account)
    }

    var currentRecentResource: ResourceFavorite? {
        guard destination == .resources, currentRecentScope != nil,
              favoriteNavigation.target == nil, relatedNavigation.target == nil, elbNavigation.target == nil else { return nil }
        return currentResource
    }

    func openFavorite(_ favorite: ResourceFavorite) {
        openSavedResource(favorite, source: .favorite)
    }

    func openSavedResource(_ favorite: ResourceFavorite, source: FavoriteNavigation.Source) {
        closeRelationships()
        relatedNavigation.cancel()
        elbNavigation.cancel()
        profileVM.loadProfiles()
        guard favoriteNavigation.begin(favorite, profiles: profileVM.profiles,
                                       selectedProfileName: profileVM.selectedProfile?.name, source: source) else { return }
        if favorite.service == .route53 {
            route53VM.selectedZone = nil
        } else {
            profileVM.selectedRegion = favorite.region
        }
        selectedService = favorite.service
        destination = .resources
        reconfigureServices()
    }

    func cancelFavoriteIfScopeChanged() {
        if !favoriteNavigation.matches(profileName: profileVM.selectedProfileID, region: profileVM.selectedRegion) {
            favoriteNavigation.cancel()
        }
    }
}
