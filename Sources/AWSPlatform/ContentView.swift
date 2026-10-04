import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var favoritesVM: FavoritesViewModel
    @EnvironmentObject private var recentsVM: RecentResourcesViewModel
    @StateObject private var favoriteNavigation = FavoriteNavigation()
    @StateObject private var relatedNavigation = SNSRelatedResourceNavigation()
    @StateObject private var profileVM: ProfileViewModel
    @StateObject private var costVM: CostViewModel
    @StateObject private var healthVM: HealthViewModel
    @StateObject private var alarmsVM: AlarmViewModel
    @StateObject private var snsVM: SNSViewModel
    @StateObject private var route53VM: Route53ViewModel
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
            if let message = relatedNavigation.error ?? favoriteNavigation.error ?? favoritesVM.storageError {
                HStack {
                    NoticeBanner(message: message)
                    if relatedNavigation.error != nil || favoriteNavigation.error != nil {
                        Button("Dismiss") {
                            relatedNavigation.cancel()
                            favoriteNavigation.cancel()
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
                        .disabled(!showingFavorites && !showingRecents && (!profileVM.isProfileReady || favoriteNavigation.target != nil || relatedNavigation.target != nil))
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
        }
        .onChange(of: destination) { selection in
            resetMonitoring()
            if selection != .resources {
                closeRelationships()
                relatedNavigation.cancel()
            }
            if selection != .resources { favoriteNavigation.cancel() }
            if selection == .costs { configureCosts() }
            if selection == .health { configureHealth() }
            loadVisibleAlarms()
            loadVisibleSNS()
            loadVisibleRoute53()
        }
        .onDisappear {
            resetMonitoring()
            closeRelationships()
            relatedNavigation.cancel()
            loginTask?.cancel()
            reconfigureTask?.cancel()
            costVM.reset()
            healthVM.reset()
            alarmsVM.reset()
            snsVM.reset()
            route53VM.reset()
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
              relatedNavigation.target == nil else { return }
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
              relatedNavigation.target == nil else { return }
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
              relatedNavigation.target == nil else { return }
        route53VM.loadIfNeeded()
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
                Text("Opening \(target.displayName)…")
                Text("\(target.profileName) · \(target.region)")
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
                        Button {
                            favoritesVM.toggle(favorite)
                        } label: {
                            Label(favoritesVM.contains(favorite) ? "Remove Favorite" : "Add Favorite",
                                  systemImage: favoritesVM.contains(favorite) ? "star.fill" : "star")
                        }
                        .disabled(favoritesVM.storageError != nil)
                        .help("Save this resource with its current account, profile, and region")
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
              favoriteNavigation.target == nil, relatedNavigation.target == nil else { return nil }
        return currentResource
    }

    private func openFavorite(_ favorite: ResourceFavorite) {
        openSavedResource(favorite, source: .favorite)
    }

    private func openSavedResource(_ favorite: ResourceFavorite, source: FavoriteNavigation.Source) {
        closeRelationships()
        relatedNavigation.cancel()
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

    private func resetMonitoring() {
        metricsVM.reset()
        logsVM.reset()
    }

    private func closeRelationships() {
        relationshipTopic = nil
        relationshipsVM.reset()
    }

    private func openRelatedResource(_ resource: SNSRelatedResource) {
        guard relatedNavigation.open(resource, currentScope: currentRelationshipScope,
                                     latestScope: { currentRelationshipScope },
                                     alarms: alarmsVM, lambda: lambdaVM, sns: snsVM) else { return }
        closeRelationships()
        favoriteNavigation.cancel()
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
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selectedService {
        case .ec2:
            if let instance = ec2VM.selectedInstance {
                EC2DetailView(instance: instance, vm: ec2VM,
                              monitoringScope: currentMonitoringScope, metricsVM: metricsVM)
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
                        Button("Back to Buckets") {
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
                Route53ZoneDetailView(zone: zone, vm: route53VM)
            } else {
                EmptyStateView(text: "Select a Route 53 hosted zone", icon: "network")
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
        reconfigureTask?.cancel()
        s3BrowsingBucket = nil
        ec2VM.reset()
        lambdaVM.reset()
        s3VM.reset()
        alarmsVM.reset()
        snsVM.reset()
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
            }
            ec2VM.configure(provider: profileVM.provider, refreshImmediately: target?.service != .ec2)
            lambdaVM.configure(provider: profileVM.provider, refreshImmediately: target?.service != .lambda)
            s3VM.configure(provider: profileVM.provider, refreshImmediately: target?.service != .s3)
            configureAlarms()
            configureSNS()
            guard let target else { return }
            switch target.service {
            case .ec2: await ec2VM.loadInstances()
            case .lambda: await lambdaVM.loadFunctions()
            case .s3: await s3VM.loadBuckets()
            case .alarms: await alarmsVM.loadAlarms()
            case .sns: await snsVM.loadTopics()
            case .route53: await route53VM.loadZones()
            }
            guard !Task.isCancelled, favoriteNavigation.target?.id == target.id else { return }
            favoriteNavigation.resolve(ec2: ec2VM, lambda: lambdaVM, s3: s3VM, alarms: alarmsVM, sns: snsVM, route53: route53VM)
        }
    }
}
