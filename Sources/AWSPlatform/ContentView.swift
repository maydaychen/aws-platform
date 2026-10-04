import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var favoritesVM: FavoritesViewModel
    @EnvironmentObject private var recentsVM: RecentResourcesViewModel
    @StateObject private var favoriteNavigation = FavoriteNavigation()
    @StateObject private var relatedNavigation = SNSRelatedResourceNavigation()
    @StateObject private var elbNavigation = ELBResourceNavigation()
    @StateObject private var profileVM: ProfileViewModel
    @StateObject private var costVM: CostViewModel
    @StateObject private var healthVM: HealthViewModel
    @StateObject private var alarmsVM: AlarmViewModel
    @StateObject private var snsVM: SNSViewModel
    @StateObject private var route53VM: Route53ViewModel
    @StateObject private var elbVM: ELBViewModel
    @StateObject private var membershipsVM: EC2TargetGroupsViewModel
    @StateObject private var securityGroupsVM: SecurityGroupsViewModel
    @StateObject private var resourceRelationshipsVM: ResourceRelationshipsViewModel
    @StateObject private var relationshipsVM: SNSRelationshipViewModel
    @StateObject private var metricsVM: ResourceMetricsViewModel
    @StateObject private var logsVM: LambdaLogsViewModel
    @StateObject private var ec2VM = EC2ViewModel()
    @StateObject private var lambdaVM = LambdaViewModel()
    @StateObject private var s3VM = S3ViewModel()

    @AppStorage("selectedService") private var selectedServiceID = AWSService.ec2.rawValue
    @State private var selectedService: AWSService = .ec2
    @State private var s3BrowsingBucket: String?
    @State private var reconfigureTask: Task<Void, Never>?
    @State private var loginTask: Task<Void, Never>?
    @State private var destination: WorkspaceDestination = .resources
    @State private var relationshipTopic: SNSTopic?
    @State private var showsResourceRelationships = false

    init() {
        let profiles = ProfileViewModel()
        _profileVM = StateObject(wrappedValue: profiles)
        let metrics = AWSMetricsService(provider: profiles.provider)
        _metricsVM = StateObject(wrappedValue: ResourceMetricsViewModel(loader: { scope, target, range in
            try await metrics.load(scope: scope, target: target, range: range)
        }))
        let logs = AWSLogsService(provider: profiles.provider)
        _logsVM = StateObject(wrappedValue: LambdaLogsViewModel(loader: { query, cursor in
            try await logs.load(query: query, cursor: cursor)
        }))
        let costs = AWSCostService(provider: profiles.provider)
        _costVM = StateObject(wrappedValue: CostViewModel(loader: { scope, query in
            try await costs.load(scope: scope, query: query)
        }))
        let health = AWSHealthService(provider: profiles.provider)
        _healthVM = StateObject(wrappedValue: HealthViewModel(
            listLoader: { try await health.loadEvents(scope: $0) },
            detailLoader: { try await health.loadDetails(scope: $0, event: $1) },
            entityLoader: { try await health.loadEntities(scope: $0, event: $1) }
        ))
        let alarms = AWSAlarmService(provider: profiles.provider)
        _relationshipsVM = StateObject(wrappedValue: SNSRelationshipViewModel(loader: {
            try await alarms.loadAlarms(scope: $0.alarmScope)
        }))
        _alarmsVM = StateObject(wrappedValue: AlarmViewModel(
            listLoader: { try await alarms.loadAlarms(scope: $0) },
            tagLoader: { try await alarms.loadTags(scope: $0, alarm: $1) },
            historyLoader: { try await alarms.loadHistory(scope: $0, alarm: $1) }
        ))
        let sns = AWSSNSService(provider: profiles.provider)
        _snsVM = StateObject(wrappedValue: SNSViewModel(
            listLoader: { try await sns.loadTopics(scope: $0) },
            attributeLoader: { try await sns.loadAttributes(scope: $0, topic: $1) },
            tagLoader: { try await sns.loadTags(scope: $0, topic: $1) },
            subscriptionLoader: { try await sns.loadSubscriptions(scope: $0, topic: $1) }
        ))
        let route53 = AWSRoute53Service(provider: profiles.provider)
        _route53VM = StateObject(wrappedValue: Route53ViewModel(
            listLoader: { try await route53.loadZones(scope: $0) },
            detailLoader: { try await route53.loadDetails(scope: $0, zone: $1) },
            recordLoader: { try await route53.loadRecords(scope: $0, zone: $1) },
            tagLoader: { try await route53.loadTags(scope: $0, zone: $1) }
        ))
        let elb = AWSELBService(provider: profiles.provider)
        _elbVM = StateObject(wrappedValue: ELBViewModel(
            loadBalancerLoader: { try await elb.loadLoadBalancers(scope: $0) },
            targetGroupLoader: { try await elb.loadTargetGroups(scope: $0) },
            listenerLoader: { try await elb.loadListeners(scope: $0, loadBalancer: $1) },
            ruleLoader: { try await elb.loadRules(scope: $0, listener: $1) },
            healthLoader: { try await elb.loadTargetHealth(scope: $0, group: $1) }
        ))
        _membershipsVM = StateObject(wrappedValue: EC2TargetGroupsViewModel(loader: {
            try await elb.loadInstanceMembership(scope: $0, instanceID: $1)
        }))
        let groups = AWSSecurityGroupService(provider: profiles.provider)
        _securityGroupsVM = StateObject(wrappedValue: SecurityGroupsViewModel(loader: {
            try await groups.loadGroups(scope: $0)
        }))
        let provider = profiles.provider
        let relations = AWSResourceRelationshipService(
            loadBalancers: { scope in
                try await AWSELBService(client: provider.relationshipELBClient(scope: scope)).loadLoadBalancers(scope: scope)
            },
            loadTargetGroups: { scope in
                try await AWSELBService(client: provider.relationshipELBClient(scope: scope)).loadTargetGroups(scope: scope)
            },
            loadTargetHealth: { scope, group in
                try await AWSELBService(client: provider.relationshipELBClient(scope: scope)).loadTargetHealth(scope: scope, group: group)
            },
            loadMembership: { scope, instanceID in
                try await AWSELBService(client: provider.relationshipELBClient(scope: scope)).loadInstanceMembership(scope: scope, instanceID: instanceID)
            },
            loadGroups: { try await groups.loadGroups(scope: $0) },
            loadInstance: { try await groups.loadInstance(scope: $0, instanceID: $1) },
            loadInstancesUsingGroup: { try await groups.loadInstancesUsingGroup(scope: $0, groupID: $1) },
            loadZones: { try await route53.loadZones(scope: $0) },
            loadRecords: { try await route53.loadRecords(scope: $0, zone: $1) }
        )
        _resourceRelationshipsVM = StateObject(wrappedValue: ResourceRelationshipsViewModel(loader: {
            try await relations.load(reference: $0, includeReverse: $1)
        }))
    }

    private var showingFavorites: Bool { destination == .favorites }
    private var showingRecents: Bool { destination == .recents }

    var body: some View {
        VStack(spacing: 0) {
            ProfileBarView(vm: profileVM, onRetry: {
                profileVM.loadProfiles()
                reconfigureServices(forceRefresh: true)
            }, onLogin: signIn, onCancelLogin: { loginTask?.cancel() },
               showsResourceRegion: destination != .costs && destination != .health
                    && !(destination == .resources && selectedService == .route53),
               globalScopeMessage: destination == .costs ? "Cost regions are selected below" : "Global service · Current account")
            if let message = elbNavigation.error ?? relatedNavigation.error ?? favoriteNavigation.error ?? favoritesVM.storageError {
                HStack {
                    NoticeBanner(message: message)
                    if elbNavigation.error != nil || relatedNavigation.error != nil || favoriteNavigation.error != nil {
                        Button(L10n.text("Dismiss", locale: locale)) {
                            relatedNavigation.cancel()
                            favoriteNavigation.cancel()
                            elbNavigation.cancel()
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            Divider()
            HSplitView {
                ServiceSidebarView(selectedService: $selectedService, destination: $destination)
                if destination == .costs {
                    costPane
                        .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
                } else if destination == .health {
                    healthPane
                        .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    middlePane
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                        .disabled(!showingFavorites && !showingRecents && (!profileVM.isProfileReady || favoriteNavigation.target != nil || relatedNavigation.target != nil || elbNavigation.target != nil))
                    resourceDetail
                        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                        .contentTransition(reduceMotion ? .identity : .opacity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: detailSelectionID)
                        .id([profileVM.selectedProfileID ?? "", selectedService == .route53 ? "global" : profileVM.selectedRegion])
                }
            }
        }
        .sheet(item: $relationshipTopic) { topic in
            SNSRelationshipView(topic: topic, snsVM: snsVM, vm: relationshipsVM,
                                onOpenResource: openRelatedResource)
        }
        .sheet(isPresented: $showsResourceRelationships, onDismiss: { resourceRelationshipsVM.reset() }) {
            ResourceRelationshipsView(vm: resourceRelationshipsVM, onOpen: openResourceRelationship, onClose: closeRelationships)
        }
        .onChange(of: detailSelectionID) { _ in
            if showsResourceRelationships { closeRelationships() }
        }
        .onChange(of: snsVM.selectedTopic?.arn) { _ in closeRelationships() }
        .onChange(of: currentRecentResource?.id) { expectedID in
            // Recheck live state: background selections and stale view updates are not visits.
            guard let resource = currentRecentResource, resource.id == expectedID else { return }
            recentsVM.recordVisit(resource, scope: currentRecentScope)
        }
        .onAppear {
            profileVM.loadProfiles()
            selectedService = AWSService(rawValue: selectedServiceID) ?? .ec2
            reconfigureServices()
        }
        .onChange(of: profileVM.selectedProfileID) { _ in
            costVM.reset()
            healthVM.reset()
            route53VM.reset()
            cancelFavoriteIfScopeChanged()
            if profileVM.isSigningIn { clearResources() }
            else { reconfigureServices() }
        }
        .onChange(of: profileVM.profileSource) { _ in
            costVM.reset()
            healthVM.reset()
            route53VM.reset()
            loginTask?.cancel()
            favoriteNavigation.cancel()
            reconfigureServices()
        }
        .onChange(of: profileVM.selectedRegion) { _ in
            cancelFavoriteIfScopeChanged()
            s3BrowsingBucket = nil
            reconfigureServices()
        }
        .onChange(of: selectedService) { _ in
            resetMonitoring()
            closeRelationships()
            if selectedService != .ec2 { membershipsVM.reset() }
            if let target = elbNavigation.target, target.service != selectedService { elbNavigation.cancel() }
            if let target = relatedNavigation.target, target.service != selectedService {
                relatedNavigation.cancel()
            }
            if let target = favoriteNavigation.target, target.service != selectedService {
                favoriteNavigation.cancel()
            }
            if s3BrowsingBucket != nil { s3VM.leaveObjectBrowser() }
            s3BrowsingBucket = nil
            selectedServiceID = selectedService.rawValue
            loadVisibleAlarms()
            loadVisibleSNS()
            loadVisibleRoute53()
            loadVisibleELB()
            loadVisibleSecurityGroups()
        }
        .onChange(of: destination) { selection in
            resetMonitoring()
            if selection != .resources {
                closeRelationships()
                relatedNavigation.cancel()
                elbNavigation.cancel()
                membershipsVM.reset()
            }
            if selection != .resources { favoriteNavigation.cancel() }
            if selection == .costs { configureCosts() }
            if selection == .health { configureHealth() }
            loadVisibleAlarms()
            loadVisibleSNS()
            loadVisibleRoute53()
            loadVisibleELB()
            loadVisibleSecurityGroups()
        }
        .onDisappear {
            resetMonitoring()
            closeRelationships()
            relatedNavigation.cancel()
            elbNavigation.cancel()
            membershipsVM.reset()
            loginTask?.cancel()
            reconfigureTask?.cancel()
            costVM.reset()
            healthVM.reset()
            alarmsVM.reset()
            snsVM.reset()
            route53VM.reset()
            elbVM.reset()
            securityGroupsVM.reset()
            Task { await profileVM.shutdown() }
        }
    }

    @ViewBuilder
    private var costPane: some View {
        if profileVM.selectedProfile == nil {
            EmptyStateView(text: profileVM.selectionPrompt, icon: "person.crop.circle")
                .padding()
        } else if !profileVM.isProfileReady {
            EmptyStateView(text: "Connect the selected profile to load costs.", icon: "cloud")
                .padding()
        } else {
            CostView(vm: costVM)
        }
    }

    private func configureCosts() {
        guard profileVM.isProfileReady, let profile = profileVM.selectedProfile,
              case .valid(let identity) = profileVM.profileStatus else { return }
        costVM.configure(scope: CostScope(profile: profile, identity: identity))
        if destination == .costs { costVM.loadIfNeeded() }
    }

    @ViewBuilder
    private var healthPane: some View {
        if profileVM.selectedProfile == nil {
            EmptyStateView(text: profileVM.selectionPrompt, icon: "person.crop.circle")
                .padding()
        } else if !profileVM.isProfileReady {
            EmptyStateView(text: "Connect the selected profile to load Health events.", icon: "heart.text.square")
                .padding()
        } else {
            HealthView(vm: healthVM)
        }
    }

    private func configureHealth() {
        guard profileVM.isProfileReady, let profile = profileVM.selectedProfile,
              case .valid(let identity) = profileVM.profileStatus else { return }
        healthVM.configure(scope: HealthScope(profile: profile, identity: identity))
        if destination == .health { healthVM.loadIfNeeded() }
    }

    private func configureAlarms() {
        guard profileVM.isProfileReady, let profile = profileVM.selectedProfile,
              case .valid(let identity) = profileVM.profileStatus else { return }
        alarmsVM.configure(scope: AlarmScope(profile: profile, identity: identity, region: profileVM.selectedRegion))
        loadVisibleAlarms()
    }

    private func loadVisibleAlarms() {
        guard destination == .resources, selectedService == .alarms,
              profileVM.isProfileReady, favoriteNavigation.target == nil,
              relatedNavigation.target == nil, elbNavigation.target == nil else { return }
        alarmsVM.loadIfNeeded()
    }

    private func configureSNS() {
        guard profileVM.isProfileReady, let profile = profileVM.selectedProfile,
              case .valid(let identity) = profileVM.profileStatus else { return }
        snsVM.configure(scope: SNSScope(profile: profile, identity: identity, region: profileVM.selectedRegion))
        loadVisibleSNS()
    }

    private func loadVisibleSNS() {
        guard destination == .resources, selectedService == .sns,
              profileVM.isProfileReady, favoriteNavigation.target == nil,
              relatedNavigation.target == nil, elbNavigation.target == nil else { return }
        snsVM.loadIfNeeded()
    }

    private func configureRoute53() {
        guard profileVM.isProfileReady, let profile = profileVM.selectedProfile,
              case .valid(let identity) = profileVM.profileStatus else { return }
        route53VM.configure(scope: Route53Scope(profile: profile, identity: identity))
        loadVisibleRoute53()
    }

    private func loadVisibleRoute53() {
        guard destination == .resources, selectedService == .route53,
              profileVM.isProfileReady, favoriteNavigation.target == nil,
              relatedNavigation.target == nil, elbNavigation.target == nil else { return }
        route53VM.loadIfNeeded()
    }

    private func configureELB() {
        guard let scope = currentMonitoringScope else { return }
        elbVM.configure(scope: scope)
        loadVisibleELB()
    }

    private func loadVisibleELB() {
        guard destination == .resources, profileVM.isProfileReady,
              favoriteNavigation.target == nil, relatedNavigation.target == nil,
              elbNavigation.target == nil else { return }
        if selectedService == .loadBalancers { elbVM.loadLoadBalancersIfNeeded() }
        if selectedService == .targetGroups { elbVM.loadTargetGroupsIfNeeded() }
    }

    private func configureSecurityGroups() {
        guard let scope = currentMonitoringScope else { return }
        securityGroupsVM.configure(scope: scope)
        loadVisibleSecurityGroups()
    }

    private func loadVisibleSecurityGroups() {
        guard destination == .resources, selectedService == .securityGroups,
              profileVM.isProfileReady, favoriteNavigation.target == nil,
              relatedNavigation.target == nil, elbNavigation.target == nil else { return }
        securityGroupsVM.loadIfNeeded()
    }

    @ViewBuilder
    private var middlePane: some View {
        if profileVM.selectedProfile == nil {
            EmptyStateView(text: "No profile selected", icon: "person.crop.circle")
        } else if showingFavorites {
            FavoritesListView(vm: favoritesVM, onOpen: openFavorite)
        } else if !profileVM.isProfileReady {
            EmptyStateView(text: "Connect the selected profile to load resources.", icon: "cloud")
        } else if showingRecents {
            RecentResourcesListView(vm: recentsVM, scope: currentRecentScope) {
                openSavedResource($0, source: .recent)
            }
        } else {
            serviceList
        }
    }

    @ViewBuilder
    private var serviceList: some View {
        switch selectedService {
        case .ec2:
            EC2ListView(vm: ec2VM)
        case .lambda:
            LambdaListView(vm: lambdaVM)
        case .s3:
            if let bucketName = s3BrowsingBucket {
                S3ObjectListView(vm: s3VM, bucketName: bucketName)
            } else {
                S3BucketListView(vm: s3VM)
            }
        case .alarms:
            AlarmListView(vm: alarmsVM)
        case .sns:
            SNSTopicListView(vm: snsVM)
        case .route53:
            Route53ZoneListView(vm: route53VM)
        case .loadBalancers:
            ELBLoadBalancerListView(vm: elbVM)
        case .targetGroups:
            ELBTargetGroupListView(vm: elbVM)
        case .securityGroups:
            SecurityGroupListView(vm: securityGroupsVM)
        }
    }

    @ViewBuilder
    private var resourceDetail: some View {
        if profileVM.selectedProfile == nil {
            EmptyStateView(text: profileVM.selectionPrompt, icon: "person.crop.circle")
                .padding()
        } else if showingFavorites {
            EmptyStateView(text: "Select a favorite from the current profile to open its saved region and resource.", icon: "star")
                .padding()
        } else if showingRecents {
            EmptyStateView(text: "Select a recent resource to reopen it in its saved region.", icon: "clock.arrow.circlepath")
                .padding()
        } else if !profileVM.isProfileReady {
            EmptyStateView(text: "Waiting for the selected profile to connect.", icon: "cloud")
                .padding()
        } else if let target = favoriteNavigation.target {
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.format("Opening %@…", target.displayName, locale: locale))
                Text("\(target.profileName) · \(target.region)")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let target = elbNavigation.target {
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.format("Opening %@…", target.name, locale: locale))
                Text("\(target.scope.profile.name) · \(target.scope.region)")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if let favorite = currentResource {
                    HStack {
                        Label(selectedService.rawValue, systemImage: selectedService.icon)
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        if let reference = currentRelationReference {
                            Button(L10n.text("View relationships", locale: locale)) { showResourceRelationships(reference) }
                        }
                        Button {
                            favoritesVM.toggle(favorite)
                        } label: {
                            Label(L10n.text(favoritesVM.contains(favorite) ? "Remove Favorite" : "Add Favorite", locale: locale),
                                  systemImage: favoritesVM.contains(favorite) ? "star.fill" : "star")
                        }
                        .disabled(favoritesVM.storageError != nil)
                        .help(L10n.text("Save this resource with its current account, profile, and region", locale: locale))
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Divider() }
                }
                detailPane
            }
        }
    }

    private var currentResource: ResourceFavorite? {
        guard case .valid(let identity) = profileVM.profileStatus,
              let profileName = profileVM.selectedProfileID else { return nil }
        let resource: (id: String, name: String)
        switch selectedService {
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
        }
        let favorite = ResourceFavorite(
            profileName: profileName, accountID: identity.account,
            region: selectedService == .route53 ? "global" : profileVM.selectedRegion,
            service: selectedService, resourceID: resource.id, displayName: resource.name
        )
        return favorite.isValid ? favorite : nil
    }

    private var currentRecentScope: RecentResourceScope? {
        guard profileVM.isProfileReady, let profile = profileVM.selectedProfile,
              case .valid(let identity) = profileVM.profileStatus else { return nil }
        return RecentResourceScope(profileName: profile.name, accountID: identity.account)
    }

    private var currentRecentResource: ResourceFavorite? {
        guard destination == .resources, currentRecentScope != nil,
              favoriteNavigation.target == nil, relatedNavigation.target == nil, elbNavigation.target == nil else { return nil }
        return currentResource
    }

    private func openFavorite(_ favorite: ResourceFavorite) {
        openSavedResource(favorite, source: .favorite)
    }

    private func openSavedResource(_ favorite: ResourceFavorite, source: FavoriteNavigation.Source) {
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

    private var currentRelationshipScope: SNSScope? {
        guard profileVM.isProfileReady, let profile = profileVM.selectedProfile,
              case .valid(let identity) = profileVM.profileStatus else { return nil }
        return SNSScope(profile: profile, identity: identity, region: profileVM.selectedRegion)
    }

    private var currentMonitoringScope: MonitoringScope? {
        guard profileVM.isProfileReady, let profile = profileVM.selectedProfile,
              case .valid(let identity) = profileVM.profileStatus else { return nil }
        return MonitoringScope(profile: profile, identity: identity, region: profileVM.selectedRegion)
    }

    private var currentRelationReference: ResourceRelationReference? {
        guard let scope = currentMonitoringScope, let resource = currentResource,
              [.ec2, .loadBalancers, .targetGroups, .securityGroups, .route53].contains(selectedService) else { return nil }
        if selectedService == .securityGroups, securityGroupsVM.selectedGroup?.ownerID != scope.accountID { return nil }
        let reference = ResourceRelationReference(scope: scope, service: selectedService,
                                                  resourceID: resource.resourceID, name: resource.displayName)
        return reference.isValid ? reference : nil
    }

    private func showResourceRelationships(_ reference: ResourceRelationReference) {
        guard let scope = currentMonitoringScope, reference.isValid, reference.scope == scope else { return }
        closeRelationships()
        resourceRelationshipsVM.configure(reference: reference)
        showsResourceRelationships = true
    }

    private func showRecordRelationships(_ record: Route53Record) {
        guard let scope = currentMonitoringScope, let zone = route53VM.selectedZone,
              route53VM.scope == scope.route53Scope, route53VM.records.contains(record) else { return }
        showResourceRelationships(ResourceRelationReference(scope: scope, service: .route53,
                                                             resourceID: zone.id, name: record.name, recordID: record.id))
    }

    private func openResourceRelationship(_ reference: ResourceRelationReference) {
        let scope = currentMonitoringScope
        closeRelationships()
        relatedNavigation.cancel()
        elbNavigation.cancel()
        guard favoriteNavigation.beginRelationship(reference, currentScope: scope, profiles: profileVM.profiles) else { return }
        if !reference.isGlobal { profileVM.selectedRegion = reference.scope.region }
        selectedService = reference.service
        destination = .resources
        reconfigureServices()
    }

    private func resetMonitoring() {
        metricsVM.reset()
        logsVM.reset()
    }

    private func closeRelationships() {
        relationshipTopic = nil
        relationshipsVM.reset()
        showsResourceRelationships = false
        resourceRelationshipsVM.reset()
    }

    private func openRelatedResource(_ resource: SNSRelatedResource) {
        elbNavigation.cancel()
        guard relatedNavigation.open(resource, currentScope: currentRelationshipScope,
                                     latestScope: { currentRelationshipScope },
                                     alarms: alarmsVM, lambda: lambdaVM, sns: snsVM) else { return }
        closeRelationships()
        favoriteNavigation.cancel()
        selectedService = resource.service
        destination = .resources
    }

    private func openELBResource(_ resource: ELBResourceReference) {
        closeRelationships()
        relatedNavigation.cancel()
        favoriteNavigation.cancel()
        guard elbNavigation.open(resource, currentScope: currentMonitoringScope,
                                 latestScope: { currentMonitoringScope }, elb: elbVM,
                                 ec2: ec2VM, lambda: lambdaVM) else { return }
        selectedService = resource.service
        destination = .resources
    }

    private func cancelFavoriteIfScopeChanged() {
        if !favoriteNavigation.matches(profileName: profileVM.selectedProfileID, region: profileVM.selectedRegion) {
            favoriteNavigation.cancel()
        }
    }

    private var detailSelectionID: String {
        switch selectedService {
        case .ec2: return "ec2/" + (ec2VM.selectedInstance?.instanceId ?? "")
        case .lambda: return "lambda/" + (lambdaVM.selectedFunction?.functionName ?? "")
        case .s3: return "s3/" + (s3BrowsingBucket ?? s3VM.selectedBucket?.name ?? "") + "/" + (s3VM.selectedObject?.key ?? "")
        case .alarms: return "alarms/" + (alarmsVM.selectedAlarm?.arn ?? "")
        case .sns: return "sns/" + (snsVM.selectedTopic?.arn ?? "")
        case .route53: return "route53/" + (route53VM.selectedZone?.id ?? "")
        case .loadBalancers: return "loadbalancer/" + (elbVM.selectedLoadBalancer?.arn ?? "")
        case .targetGroups: return "targetgroup/" + (elbVM.selectedTargetGroup?.arn ?? "")
        case .securityGroups: return "securitygroup/" + (securityGroupsVM.selectedGroup?.id ?? "")
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selectedService {
        case .ec2:
            if let instance = ec2VM.selectedInstance {
                EC2DetailView(instance: instance, vm: ec2VM,
                              monitoringScope: currentMonitoringScope, metricsVM: metricsVM,
                              membershipsVM: membershipsVM, onOpenELB: openELBResource)
            } else {
                EmptyStateView(text: "Select an EC2 instance", icon: "server.rack")
            }
        case .lambda:
            if let function = lambdaVM.selectedFunction {
                LambdaDetailView(function: function, vm: lambdaVM,
                                 monitoringScope: currentMonitoringScope, metricsVM: metricsVM, logsVM: logsVM)
            } else {
                EmptyStateView(text: "Select a Lambda function", icon: "function")
            }
        case .s3:
            if let bucket = s3VM.selectedBucket, s3BrowsingBucket == nil {
                S3BucketDetailView(bucket: bucket) {
                    s3BrowsingBucket = bucket.name
                    s3VM.navigateToPrefix(bucket: bucket.name, prefix: "")
                }
            } else if let bucketName = s3BrowsingBucket {
                VStack(spacing: 0) {
                    HStack {
                        Button(L10n.text("Back to Buckets", locale: locale)) {
                            s3VM.leaveObjectBrowser()
                            s3BrowsingBucket = nil
                        }
                        Spacer()
                        Text(bucketName)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(bucketName)
                    }
                    .padding()
                    Divider()
                    if let object = s3VM.selectedObject {
                        S3ObjectDetailView(object: object)
                    } else {
                        EmptyStateView(text: "Select an object or folder", icon: "doc")
                    }
                }
            } else {
                EmptyStateView(text: "Select an S3 bucket", icon: "externaldrive")
            }
        case .alarms:
            if let alarm = alarmsVM.selectedAlarm {
                AlarmDetailView(alarm: alarm, vm: alarmsVM, scope: currentRelationshipScope,
                                onOpenResource: openRelatedResource)
            } else {
                EmptyStateView(text: "Select a CloudWatch alarm", icon: "bell.badge")
            }
        case .sns:
            if let topic = snsVM.selectedTopic {
                SNSTopicDetailView(topic: topic, vm: snsVM, onViewRelationships: {
                    guard let scope = currentRelationshipScope, scope == snsVM.scope else { return }
                    relationshipTopic = topic
                })
            } else {
                EmptyStateView(text: "Select an SNS topic", icon: "dot.radiowaves.left.and.right")
            }
        case .route53:
            if let zone = route53VM.selectedZone {
                Route53ZoneDetailView(zone: zone, vm: route53VM, onShowRelationships: showRecordRelationships)
            } else {
                EmptyStateView(text: "Select a Route 53 hosted zone", icon: "network")
            }
        case .loadBalancers:
            if let lb = elbVM.selectedLoadBalancer {
                ELBLoadBalancerDetailView(loadBalancer: lb, vm: elbVM, onOpen: openELBResource)
            } else {
                EmptyStateView(text: "Select a load balancer", icon: "point.3.connected.trianglepath.dotted")
            }
        case .targetGroups:
            if let group = elbVM.selectedTargetGroup {
                ELBTargetGroupDetailView(group: group, vm: elbVM, onOpen: openELBResource)
            } else {
                EmptyStateView(text: "Select a target group", icon: "scope")
            }
        case .securityGroups:
            if let group = securityGroupsVM.selectedGroup {
                SecurityGroupDetailView(group: group, vm: securityGroupsVM)
            } else {
                EmptyStateView(text: "Select a security group", icon: "shield.lefthalf.filled")
            }
        }
    }

    private func signIn() {
        guard profileVM.canSignIn, loginTask == nil else { return }
        costVM.reset()
        healthVM.reset()
        route53VM.reset()
        clearResources()
        favoriteNavigation.cancel()
        loginTask = Task {
            _ = await profileVM.signIn()
            loginTask = nil
        }
    }

    private func clearResources() {
        resetMonitoring()
        closeRelationships()
        relatedNavigation.cancel()
        elbNavigation.cancel()
        membershipsVM.reset()
        reconfigureTask?.cancel()
        s3BrowsingBucket = nil
        ec2VM.reset()
        lambdaVM.reset()
        s3VM.reset()
        alarmsVM.reset()
        snsVM.reset()
        elbVM.reset()
        securityGroupsVM.reset()
    }

    private func reconfigureServices(forceRefresh: Bool = false) {
        if forceRefresh {
            costVM.reset()
            healthVM.reset()
            route53VM.reset()
        }
        clearResources()
        profileVM.beginConfiguration()

        reconfigureTask = Task {
            do {
                try await Task.sleep(nanoseconds: 75_000_000)
            } catch {
                return
            }
            let isValid = await profileVM.configureProvider(forceRefresh: forceRefresh)
            guard !Task.isCancelled else { return }
            guard isValid else {
                if favoriteNavigation.target != nil {
                    favoriteNavigation.failConnection()
                }
                return
            }
            configureCosts()
            configureHealth()
            configureRoute53()
            let target = favoriteNavigation.target
            if target != nil {
                guard case .valid(let identity) = profileVM.profileStatus,
                      favoriteNavigation.verifyAccount(identity.account) else { return }
                if favoriteNavigation.relationshipReference != nil,
                   !favoriteNavigation.validateRelationshipScope(currentMonitoringScope) { return }
            }
            ec2VM.configure(provider: profileVM.provider, refreshImmediately: target?.service != .ec2)
            lambdaVM.configure(provider: profileVM.provider, refreshImmediately: target?.service != .lambda)
            s3VM.configure(provider: profileVM.provider, refreshImmediately: target?.service != .s3)
            configureAlarms()
            configureSNS()
            configureELB()
            configureSecurityGroups()
            guard let target else { return }
            switch target.service {
            case .ec2: await ec2VM.loadInstances(selectFirstIfNeeded: favoriteNavigation.relationshipReference == nil)
            case .lambda: await lambdaVM.loadFunctions(selectFirstIfNeeded: favoriteNavigation.relationshipReference == nil)
            case .s3: await s3VM.loadBuckets()
            case .alarms: await alarmsVM.loadAlarms()
            case .sns: await snsVM.loadTopics()
            case .route53: await route53VM.loadZones()
            case .loadBalancers: await elbVM.loadLoadBalancers()
            case .targetGroups: await elbVM.loadTargetGroups()
            case .securityGroups: await securityGroupsVM.loadGroups()
            }
            guard !Task.isCancelled, favoriteNavigation.target?.id == target.id else { return }
            if favoriteNavigation.relationshipReference != nil {
                await favoriteNavigation.resolveRelationship(ec2: ec2VM, lambda: lambdaVM, s3: s3VM,
                    alarms: alarmsVM, sns: snsVM, route53: route53VM, elb: elbVM, securityGroups: securityGroupsVM,
                    latestScope: { currentMonitoringScope })
            } else {
                favoriteNavigation.resolve(ec2: ec2VM, lambda: lambdaVM, s3: s3VM, alarms: alarmsVM, sns: snsVM,
                                           route53: route53VM, elb: elbVM, securityGroups: securityGroupsVM)
            }
        }
    }
}
