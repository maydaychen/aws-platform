import Foundation
import SotoCore

@MainActor
final class ProfileViewModel: ObservableObject {
    typealias ProfileValidator = (AWSProfile, String) async throws -> AWSIdentity
    typealias BindingValidator = @MainActor (AWSServiceProvider) async throws -> AWSServiceProvider.Validation
    typealias SSOLogin = @MainActor (String, AWSConfigurationPaths) async throws -> Void
    typealias ConfigurationLoader = @Sendable () async throws -> ConfigReader.Configuration

    @Published var profiles: [AWSProfile] = []
    @Published private(set) var sessions: [AWSSOSession] = []
    @Published private(set) var profileSource: AWSProfileSource?
    @Published private(set) var selectedProfileID: AWSProfile.ID?
    @Published private(set) var signedInSessionID: String?
    @Published var selectedRegion = "us-east-1"
    @Published var isValidatingProfile = false
    @Published var profileStatus: ProfileStatus = .idle
    @Published private(set) var isSigningIn = false
    @Published private(set) var loginMessage: String?
    @Published private(set) var requiresSSOLogin = false
    @Published private(set) var identityFailureID = UUID()
    @Published private(set) var configurationError: AWSConfigurationReadError?
    @Published private(set) var isLoadingConfiguration = false

    private let savedSessionKey = "selectedSSOSessionID"
    private var hasLoadedConfiguration = false
    private var validatedProfileID: String?
    private var validatedRegion: String?
    private var validatedBindingGeneration: UUID?
    private var invalidatedBindingGeneration: UUID?
    private let defaults: UserDefaults
    private let profileValidator: ProfileValidator?
    private let bindingValidator: BindingValidator
    private let ssoLogin: SSOLogin
    private var configurationGeneration = 0
    private var identityTask: Task<Void, Never>?
    private var configurationLoadTask: Task<ConfigReader.Configuration, Error>?
    private var configurationLoadGeneration = 0

    let provider: AWSServiceProvider

    private static let knownRegions: [Region] = [
        .afsouth1, .apeast1, .apeast2, .apnortheast1, .apnortheast2, .apnortheast3,
        .apsouth1, .apsouth2, .apsoutheast1, .apsoutheast2, .apsoutheast3,
        .apsoutheast4, .apsoutheast5, .apsoutheast6, .apsoutheast7,
        .cacentral1, .cawest1, .cnnorth1, .cnnorthwest1, .eucentral1, .eucentral2,
        .eunorth1, .eusouth1, .eusouth2, .euwest1, .euwest2, .euwest3,
        .euscdeeast1, .ilcentral1, .mecentral1, .mesouth1, .mxcentral1, .saeast1,
        .useast1, .useast2, .uswest1, .uswest2, .usgoveast1, .usgovwest1
    ]

    var availableRegions: [String] {
        Set(Self.knownRegions.map(\.rawValue) + profiles.map(\.region) + [selectedRegion])
            .filter { !$0.isEmpty }.sorted()
    }

    var isProfileReady: Bool {
        if case .valid = profileStatus, let profile = selectedProfile {
            return validatedProfileID == profile.id && validatedRegion == selectedRegion
        }
        return false
    }

    var canSignIn: Bool {
        selectedSession != nil && !isSigningIn && !isValidatingProfile && !isLoadingConfiguration
    }

    @discardableResult
    func selectCustomRegion(_ input: String) -> Bool {
        let region = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard region.range(of: "^[a-z]{2}(?:-[a-z0-9]+)+-[0-9]+$", options: .regularExpression) != nil else {
            return false
        }
        selectedRegion = region
        return true
    }

    init(
        defaults: UserDefaults = .standard,
        provider: AWSServiceProvider = AWSServiceProvider(),
        profileValidator: ProfileValidator? = nil,
        bindingValidator: @escaping BindingValidator = { try await $0.validateBinding() },
        ssoLogin: @escaping SSOLogin = { session, paths in
            try await AWSSSOLoginService().login(session: session, paths: paths)
        }
    ) {
        self.defaults = defaults
        self.provider = provider
        self.profileValidator = profileValidator
        self.bindingValidator = bindingValidator
        self.ssoLogin = ssoLogin
        defaults.removeObject(forKey: "profileAccountNames.v1")
        identityTask = Task { [weak self, weak provider] in
            guard let provider else { return }
            for await token in provider.identityInvalidations {
                guard !Task.isCancelled else { return }
                await self?.handleIdentityFailure(token)
            }
        }
    }

    deinit {
        identityTask?.cancel()
        configurationLoadTask?.cancel()
    }

    func handleIdentityFailure(_ token: UUID) async {
        guard await provider.isCurrentIdentityFailure(token) else { return }
        // A reused binding can fail while its validation result is in flight.
        invalidatedBindingGeneration = token
        guard validatedBindingGeneration == token, case .valid = profileStatus else { return }
        reportIdentityFailure()
    }

    private func reportIdentityFailure() {
        validatedProfileID = nil
        validatedRegion = nil
        validatedBindingGeneration = nil
        profileStatus = .failed(AWSServiceError.identityChanged.localizedDescription)
        identityFailureID = UUID()
    }

    var selectedSession: AWSSOSession? {
        guard case .session(let id) = profileSource else { return nil }
        return sessions.first { $0.id == id }
    }

    var availableProfiles: [AWSProfile] {
        switch profileSource {
        case .session(let id) where selectedSession != nil:
            return profiles.filter { $0.ssoSessionName == id }
        case .other:
            return profiles.filter { $0.ssoSessionName == nil }
        default:
            return []
        }
    }

    var selectedProfile: AWSProfile? {
        availableProfiles.first { $0.id == selectedProfileID }
    }

    func accountID(for profile: AWSProfile) -> String? {
        if selectedProfileID == profile.id, case .valid(let identity) = profileStatus {
            return identity.account
        }
        return profile.ssoAccountID
    }

    func profileSubtitle(_ profile: AWSProfile) -> String {
        var parts: [String] = []
        if let role = profile.ssoRoleName, !role.isEmpty { parts.append(role) }
        if let accountID = accountID(for: profile) { parts.append(accountID) }
        return parts.joined(separator: " · ")
    }

    func filteredProfiles(matching query: String) -> [AWSProfile] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return availableProfiles.filter { profile in
            let fields = [profile.name, profile.ssoRoleName ?? "", accountID(for: profile) ?? ""]
            return terms.allSatisfy { term in
                fields.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
    }

    var selectionPrompt: String {
        if isSigningIn { return "Complete session login, then select a profile to load resources." }
        if profileSource == nil { return "Select an SSO session to sign in, then choose a profile." }
        if availableProfiles.isEmpty {
            return "No profiles are configured for this selection. Add a profile to your AWS configuration, then reload."
        }
        return "Select a profile to load resources. No account is selected automatically."
    }

    func reloadConfiguration(
        configurationLoader: @escaping ConfigurationLoader = { try ConfigReader.readConfiguration() }
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        configurationLoadTask?.cancel()
        configurationLoadGeneration += 1
        let generation = configurationLoadGeneration
        isLoadingConfiguration = true
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try await configurationLoader()
        }
        configurationLoadTask = task
        defer {
            if configurationLoadGeneration == generation {
                configurationLoadTask = nil
                isLoadingConfiguration = false
            }
        }
        do {
            let loaded = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard generation == configurationLoadGeneration, !Task.isCancelled else { return false }
            loadProfiles(loaded.profiles, sessions: loaded.sessions)
            return true
        } catch {
            guard generation == configurationLoadGeneration, !Task.isCancelled, !(error is CancellationError) else { return false }
            self.profiles = []
            self.sessions = []
            profileSource = nil
            signedInSessionID = nil
            hasLoadedConfiguration = false
            clearProfileSelection()
            configurationError = error as? AWSConfigurationReadError ?? .unavailable
            return false
        }
    }

    func loadProfiles(_ profiles: [AWSProfile], sessions: [AWSSOSession]? = nil) {
        let previousProfile = selectedProfile
        self.profiles = profiles
        self.sessions = sessions ?? self.sessions
        configurationError = nil
        if !hasLoadedConfiguration, let saved = defaults.string(forKey: savedSessionKey),
           self.sessions.contains(where: { $0.id == saved }) {
            profileSource = .session(saved)
        }
        hasLoadedConfiguration = true
        if case .session = profileSource, selectedSession == nil { selectSource(nil) }
        if previousProfile != selectedProfile || selectedProfile == nil {
            clearProfileSelection()
        }
    }

    func selectSource(_ source: AWSProfileSource?) {
        let validSource: AWSProfileSource?
        if case .session(let id) = source, !sessions.contains(where: { $0.id == id }) {
            validSource = nil
        } else {
            validSource = source
        }
        guard profileSource != validSource else { return }
        profileSource = validSource
        signedInSessionID = nil
        if case .session(let id) = validSource { defaults.set(id, forKey: savedSessionKey) }
        else { defaults.removeObject(forKey: savedSessionKey) }
        clearProfileSelection()
    }

    func selectProfile(id: AWSProfile.ID?) {
        guard !isSigningIn else { return }
        guard let id, let profile = availableProfiles.first(where: { $0.id == id }) else {
            clearProfileSelection()
            return
        }
        guard selectedProfileID != id else { return }
        clearProfileSelection()
        selectedProfileID = profile.id
        selectedRegion = profile.region
    }

    private func clearProfileSelection() {
        configurationGeneration += 1
        selectedProfileID = nil
        validatedProfileID = nil
        validatedRegion = nil
        validatedBindingGeneration = nil
        loginMessage = nil
        requiresSSOLogin = false
        isValidatingProfile = false
        profileStatus = .idle
    }

    func beginConfiguration() {
        configurationGeneration += 1
        if selectedProfile != nil { loginMessage = nil }
        requiresSSOLogin = false
        isValidatingProfile = selectedProfile != nil
        profileStatus = selectedProfile == nil ? .idle : .checking
    }

    func signIn() async -> Bool {
        guard canSignIn, let session = selectedSession else { return false }
        clearProfileSelection()
        signedInSessionID = nil
        let generation = configurationGeneration
        isSigningIn = true
        loginMessage = nil
        defer { isSigningIn = false }
        do {
            await provider.shutdown()
            try Task.checkCancellation()
            try await ssoLogin(session.name, AWSConfigurationPaths())
            try Task.checkCancellation()
            guard generation == configurationGeneration, selectedSession?.id == session.id else { return false }
            signedInSessionID = session.id
            // Session authorization does not select an account or load any resource.
            return true
        } catch {
            guard generation == configurationGeneration, selectedSession?.id == session.id else { return false }
            if error is CancellationError {
                loginMessage = "SSO login cancelled. You can try again when ready."
            } else if let error = error as? AWSSSOLoginService.LoginError {
                loginMessage = error.localizedDescription
            } else {
                loginMessage = AWSSSOLoginService.LoginError.failed.localizedDescription
            }
            return false
        }
    }

    func configureProvider(forceRefresh: Bool = false) async -> Bool {
        configurationGeneration += 1
        let generation = configurationGeneration
        let profile = selectedProfile
        let region = selectedRegion

        isValidatingProfile = profile != nil
        requiresSSOLogin = false
        profileStatus = profile == nil ? .idle : .checking
        defer {
            if generation == configurationGeneration {
                isValidatingProfile = false
            }
        }

        guard let profile else {
            await provider.configure(profile: nil, region: region)
            guard generation == configurationGeneration else { return false }
            profileStatus = .idle
            return false
        }

        do {
            try Task.checkCancellation()
            let identity: AWSIdentity
            let bindingGeneration: UUID?
            if let profileValidator {
                identity = try await profileValidator(profile, region)
                bindingGeneration = nil
            } else {
                await provider.configure(profile: profile, region: region, forceRefresh: forceRefresh)
                try Task.checkCancellation()
                let validation = try await bindingValidator(provider)
                identity = validation.identity
                bindingGeneration = validation.generation
            }
            try Task.checkCancellation()
            guard generation == configurationGeneration else { return false }
            if let bindingGeneration, bindingGeneration == invalidatedBindingGeneration {
                throw AWSServiceError.identityChanged
            }
            validatedProfileID = profile.id
            validatedRegion = region
            validatedBindingGeneration = bindingGeneration
            profileStatus = .valid(identity)
            return true
        } catch is CancellationError {
            if generation == configurationGeneration {
                profileStatus = .idle
            }
            return false
        } catch {
            guard generation == configurationGeneration else { return false }
            if error as? AWSServiceError == .identityChanged {
                reportIdentityFailure()
                return false
            }
            requiresSSOLogin = profile.isSSO && UserFacingError.requiresSSOLogin(error)
            if requiresSSOLogin { signedInSessionID = nil }
            profileStatus = .failed(UserFacingError.loginMessage(for: error, profileName: profile.name))
            return false
        }
    }

    func shutdown() async {
        configurationLoadGeneration += 1
        configurationLoadTask?.cancel()
        configurationLoadTask = nil
        isLoadingConfiguration = false
        configurationGeneration += 1
        isValidatingProfile = false
        await provider.shutdown()
    }

}

enum ProfileStatus: Hashable {
    case idle
    case checking
    case valid(AWSIdentity)
    case failed(String)
}

enum AWSProfileSource: Hashable {
    case session(String)
    case other
}
