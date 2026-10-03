import SwiftUI

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var favoritesVM: FavoritesViewModel
    @StateObject private var favoriteNavigation = FavoriteNavigation()
    @StateObject private var profileVM = ProfileViewModel()
    @StateObject private var ec2VM = EC2ViewModel()
    @StateObject private var lambdaVM = LambdaViewModel()
    @StateObject private var s3VM = S3ViewModel()

    @AppStorage("selectedService") private var selectedServiceID = AWSService.ec2.rawValue
    @State private var selectedService: AWSService = .ec2
    @State private var s3BrowsingBucket: String?
    @State private var reconfigureTask: Task<Void, Never>?
    @State private var loginTask: Task<Void, Never>?
    @State private var showingFavorites = false

    var body: some View {
        VStack(spacing: 0) {
            ProfileBarView(vm: profileVM, onRetry: {
                profileVM.loadProfiles()
                reconfigureServices(forceRefresh: true)
            }, onLogin: signIn, onCancelLogin: { loginTask?.cancel() })
            if let message = favoriteNavigation.error ?? favoritesVM.storageError {
                HStack {
                    NoticeBanner(message: message)
                    if favoriteNavigation.error != nil {
                        Button("Dismiss") { favoriteNavigation.cancel() }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            Divider()
            HSplitView {
                ServiceSidebarView(selectedService: $selectedService, showingFavorites: $showingFavorites)
                middlePane
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                    .disabled(!showingFavorites && (!profileVM.isProfileReady || favoriteNavigation.target != nil))
                resourceDetail
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                    .contentTransition(reduceMotion ? .identity : .opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: detailSelectionID)
                    .id([profileVM.selectedProfileID ?? "", profileVM.selectedRegion])
            }
        }
        .onAppear {
            profileVM.loadProfiles()
            selectedService = AWSService(rawValue: selectedServiceID) ?? .ec2
            reconfigureServices()
        }
        .onChange(of: profileVM.selectedProfileID) { _ in
            cancelFavoriteIfScopeChanged()
            if profileVM.isSigningIn { clearResources() }
            else { reconfigureServices() }
        }
        .onChange(of: profileVM.profileSource) { _ in
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
            if let target = favoriteNavigation.target, target.service != selectedService {
                favoriteNavigation.cancel()
            }
            if s3BrowsingBucket != nil { s3VM.leaveObjectBrowser() }
            s3BrowsingBucket = nil
            selectedServiceID = selectedService.rawValue
        }
        .onChange(of: showingFavorites) { isShowing in
            if isShowing { favoriteNavigation.cancel() }
        }
        .onDisappear {
            loginTask?.cancel()
            reconfigureTask?.cancel()
            Task { await profileVM.shutdown() }
        }
    }

    @ViewBuilder
    private var middlePane: some View {
        if profileVM.selectedProfile == nil {
            EmptyStateView(text: "No profile selected", icon: "person.crop.circle")
        } else if showingFavorites {
            FavoritesListView(vm: favoritesVM, onOpen: openFavorite)
        } else if !profileVM.isProfileReady {
            EmptyStateView(text: "Connect the selected profile to load resources.", icon: "cloud")
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
                if let favorite = currentFavorite {
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

    private var currentFavorite: ResourceFavorite? {
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
        }
        let favorite = ResourceFavorite(
            profileName: profileName, accountID: identity.account, region: profileVM.selectedRegion,
            service: selectedService, resourceID: resource.id, displayName: resource.name
        )
        return favorite.isValid ? favorite : nil
    }

    private func openFavorite(_ favorite: ResourceFavorite) {
        profileVM.loadProfiles()
        guard favoriteNavigation.begin(favorite, profiles: profileVM.profiles,
                                       selectedProfileName: profileVM.selectedProfile?.name) else { return }
        profileVM.selectedRegion = favorite.region
        selectedService = favorite.service
        showingFavorites = false
        reconfigureServices()
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
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selectedService {
        case .ec2:
            if let instance = ec2VM.selectedInstance {
                EC2DetailView(instance: instance, vm: ec2VM)
            } else {
                EmptyStateView(text: "Select an EC2 instance", icon: "server.rack")
            }
        case .lambda:
            if let function = lambdaVM.selectedFunction {
                LambdaDetailView(function: function, vm: lambdaVM)
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
        }
    }

    private func signIn() {
        guard profileVM.canSignIn, loginTask == nil else { return }
        clearResources()
        favoriteNavigation.cancel()
        loginTask = Task {
            _ = await profileVM.signIn()
            loginTask = nil
        }
    }

    private func clearResources() {
        reconfigureTask?.cancel()
        s3BrowsingBucket = nil
        ec2VM.reset()
        lambdaVM.reset()
        s3VM.reset()
    }

    private func reconfigureServices(forceRefresh: Bool = false) {
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
                    favoriteNavigation.fail("Favorite could not be opened. Resolve the connection error, then open it again from Favorites.")
                }
                return
            }
            let target = favoriteNavigation.target
            if target != nil {
                guard case .valid(let identity) = profileVM.profileStatus,
                      favoriteNavigation.verifyAccount(identity.account) else { return }
            }
            ec2VM.configure(provider: profileVM.provider, refreshImmediately: target?.service != .ec2)
            lambdaVM.configure(provider: profileVM.provider, refreshImmediately: target?.service != .lambda)
            s3VM.configure(provider: profileVM.provider, refreshImmediately: target?.service != .s3)
            guard let target else { return }
            switch target.service {
            case .ec2: await ec2VM.loadInstances()
            case .lambda: await lambdaVM.loadFunctions()
            case .s3: await s3VM.loadBuckets()
            }
            guard !Task.isCancelled, favoriteNavigation.target?.id == target.id else { return }
            favoriteNavigation.resolve(ec2: ec2VM, lambda: lambdaVM, s3: s3VM)
        }
    }
}
