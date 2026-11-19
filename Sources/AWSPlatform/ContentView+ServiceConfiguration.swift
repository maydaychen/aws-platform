extension ContentView {
    func resolveResourceNavigation(_ target: ResourceFavorite) async {
        switch target.service {
        case .logs: break
        case .codeCommit: codeCommitVM.refresh(); await codeCommitVM.waitForLoading()
        case .rds: rdsVM.refresh(); await rdsVM.waitForLoading()
        case .autoScaling: autoScalingVM.refresh(); await autoScalingVM.waitForLoading()
        case .ec2: await ec2VM.loadInstances(selectFirstIfNeeded: favoriteNavigation.relationshipReference == nil)
        case .lambda: await lambdaVM.loadFunctions(selectFirstIfNeeded: favoriteNavigation.relationshipReference == nil)
        case .s3: await s3VM.loadBuckets()
        case .alarms: await alarmsVM.loadAlarms()
        case .sns: await snsVM.loadTopics()
        case .route53: await route53VM.loadZones()
        case .loadBalancers: await elbVM.loadLoadBalancers()
        case .targetGroups: await elbVM.loadTargetGroups()
        case .securityGroups: await securityGroupsVM.loadGroups()
        case .ebsVolumes: await volumesVM.loadResources()
        case .ebsSnapshots: await snapshotsVM.loadResources()
        }
        guard !Task.isCancelled, favoriteNavigation.target?.id == target.id else { return }
        if favoriteNavigation.relationshipReference != nil {
            await favoriteNavigation.resolveRelationship(ec2: ec2VM, lambda: lambdaVM, s3: s3VM,
                alarms: alarmsVM, sns: snsVM, route53: route53VM, elb: elbVM, securityGroups: securityGroupsVM,
                latestScope: { currentMonitoringScope })
        } else {
            favoriteNavigation.resolve(ec2: ec2VM, lambda: lambdaVM, s3: s3VM, alarms: alarmsVM, sns: snsVM,
                                       route53: route53VM, elb: elbVM, securityGroups: securityGroupsVM,
                                       volumes: volumesVM, snapshots: snapshotsVM, codeCommit: codeCommitVM,
                                       rds: rdsVM, autoScaling: autoScalingVM, currentScope: currentMonitoringScope)
        }
    }
}
