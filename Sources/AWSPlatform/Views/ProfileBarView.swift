import SwiftUI

struct ProfileBarView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: ProfileViewModel
    let onRetry: () -> Void
    var onLogin: () -> Void = {}
    var onCancelLogin: () -> Void = {}
    var showsResourceRegion = true
    var globalScopeMessage = "Global service · Current account"
    @State private var isCustomRegionPresented = false
    @State private var customRegion = ""
    @State private var regionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.controlSpacing) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: WorkspaceLayout.contextGroupSpacing) {
                    sessionAndProfileControls
                    regionControls
                }
                VStack(alignment: .leading, spacing: WorkspaceLayout.contextGroupSpacing) {
                    sessionAndProfileControls
                    regionControls
                }
            }
            connectionControls
            if vm.isSigningIn {
                Text(L10n.text("Complete SSO authorization in your browser. This may take up to 5 minutes. If no browser opens, cancel and sign in from Terminal.", locale: locale))
                    .font(.caption).foregroundColor(.secondary)
            } else if let message = vm.loginMessage {
                NoticeBanner(message: message)
            } else if case .failed(let message) = vm.profileStatus {
                NoticeBanner(message: message)
            } else if vm.selectedProfile == nil {
                Text(L10n.text(vm.selectionPrompt, locale: locale)).font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, WorkspaceLayout.controlSpacing)
        .background(.bar)
    }

    private var sessionAndProfileControls: some View {
        HStack(alignment: .top, spacing: WorkspaceLayout.contextGroupSpacing) {
            contextGroup("SSO Session") {
                HStack(spacing: WorkspaceLayout.controlSpacing) {
                    Picker(L10n.text("SSO Session", locale: locale), selection: Binding(
                        get: { vm.profileSource }, set: { vm.selectSource($0) }
                    )) {
                        Text(L10n.text("Select session", locale: locale)).tag(Optional<AWSProfileSource>.none)
                        ForEach(vm.sessions) { session in
                            Text(session.name).tag(Optional(AWSProfileSource.session(session.id)))
                        }
                        Divider()
                        Text(L10n.text("Other profiles", locale: locale)).tag(Optional(AWSProfileSource.other))
                    }
                    .labelsHidden()
                    .frame(minWidth: WorkspaceLayout.sessionMinimum, maxWidth: WorkspaceLayout.sessionMaximum, alignment: .leading)
                    .help(vm.selectedSession?.name ?? L10n.text("Select session", locale: locale))
                    if vm.isSigningIn {
                        Button(L10n.text("Cancel Login", locale: locale), action: onCancelLogin)
                            .fixedSize()
                    } else if vm.selectedSession != nil {
                        Button(L10n.text("SSO Login", locale: locale), action: onLogin)
                            .fixedSize()
                            .disabled(!vm.canSignIn)
                            .help(L10n.text("Sign in to this session. Choose a profile afterwards to load resources.", locale: locale))
                    }
                }
            }
            contextGroup("Query identity · Profile") {
                ProfilePickerView(vm: vm)
                    .frame(minWidth: WorkspaceLayout.profileMinimum, maxWidth: .infinity)
                    .help(vm.selectedProfile.map {
                        [$0.name, vm.profileSubtitle($0)].filter { !$0.isEmpty }.joined(separator: "\n")
                    } ?? L10n.text("Select profile", locale: locale))
            }
            .frame(minWidth: WorkspaceLayout.profileMinimum, maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var regionControls: some View {
        contextGroup("Query region") {
            if showsResourceRegion {
                resourceRegionControls
            } else {
                Label(L10n.text(globalScopeMessage, locale: locale), systemImage: "globe")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var connectionControls: some View {
        HStack(alignment: .top, spacing: WorkspaceLayout.controlSpacing) {
            profileStatusView
            Spacer(minLength: 0)
            Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
                .disabled(vm.isValidatingProfile || vm.isSigningIn)
                .accessibilityLabel(L10n.text(vm.selectedProfile == nil ? "Reload Config" : "Retry Connection", locale: locale))
                .help(L10n.text("Reload profiles and revalidate credentials after signing in", locale: locale))
        }
    }

    @ViewBuilder
    private var resourceRegionControls: some View {
        HStack(spacing: WorkspaceLayout.controlSpacing) {
            Picker(L10n.text("Region", locale: locale), selection: $vm.selectedRegion) {
                ForEach(vm.availableRegions, id: \.self) { region in
                    Text(AWSRegionCatalog.displayName(for: region, locale: locale)).tag(region)
                }
            }
            .labelsHidden()
            .frame(width: WorkspaceLayout.regionWidth)
            .disabled(vm.selectedProfile == nil || vm.isSigningIn)
            Button {
                customRegion = vm.selectedRegion
                regionError = nil
                isCustomRegionPresented = true
            } label: {
                Image(systemName: "pencil")
            }
            .help(L10n.text("Enter another AWS region", locale: locale))
            .disabled(vm.selectedProfile == nil || vm.isSigningIn)
            .accessibilityLabel(L10n.text("Enter another AWS region", locale: locale))
            .popover(isPresented: $isCustomRegionPresented) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("AWS Region", locale: locale)).font(.headline)
                    TextField(L10n.text("Region code", locale: locale), text: $customRegion)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyCustomRegion)
                    if let regionError {
                        Text(L10n.text(regionError, locale: locale)).font(.caption).foregroundColor(.orange)
                    }
                    Button(L10n.text("Use Region", locale: locale), action: applyCustomRegion)
                }
                .padding()
                .frame(width: 280)
            }
        }
    }

    private func contextGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceLayout.contextGroupTitleSpacing) {
            Text(L10n.text(title, locale: locale))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize()
            content()
        }
        .padding(.top, WorkspaceLayout.contextGroupTopPadding)
    }

    private func applyCustomRegion() {
        if vm.selectCustomRegion(customRegion) {
            isCustomRegionPresented = false
        } else {
            regionError = "Enter a region code such as eu-central-2."
        }
    }

    @ViewBuilder
    private var profileStatusView: some View {
        if vm.isSigningIn {
            progressStatus("Waiting for browser authorization…")
        } else {
            switch vm.profileStatus {
            case .idle:
                if let session = vm.selectedSession, vm.signedInSessionID == session.id {
                    Label(L10n.text("Session signed in · Select profile", locale: locale), systemImage: "checkmark.circle")
                        .font(.caption).foregroundColor(.green)
                } else {
                    Label(L10n.text(vm.selectedProfile == nil ? "No profile selected" : "Profile not verified", locale: locale), systemImage: "circle.dotted")
                        .font(.caption).foregroundColor(.secondary)
                }
            case .checking:
                progressStatus("Checking connection…")
                    .help(L10n.text("Checking AWS profile", locale: locale))
            case .valid(let identity):
                verifiedIdentity(identity)
            case .failed(let message):
                Label(L10n.text(vm.requiresSSOLogin ? "Login required" : "Connection failed", locale: locale), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .help(L10n.text(message, locale: locale))
            }
        }
    }

    private func progressStatus(_ message: String) -> some View {
        HStack(spacing: WorkspaceLayout.controlSpacing) {
            ProgressView().controlSize(.small)
            Text(L10n.text(message, locale: locale)).font(.caption).foregroundColor(.secondary)
        }
    }

    private func verifiedIdentity(_ identity: AWSIdentity) -> some View {
        let summary = ProfileIdentitySummary(identity: identity)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: WorkspaceLayout.controlSpacing) {
                verifiedLabel
                identityText(summary).fixedSize()
            }
            VStack(alignment: .leading, spacing: WorkspaceLayout.contextGroupTitleSpacing) {
                verifiedLabel
                identityText(summary)
            }
        }
        .help("\(identity.account)\n\(identity.arn)")
    }

    private var verifiedLabel: some View {
        Label(L10n.text("Profile verified", locale: locale), systemImage: "checkmark.circle")
            .font(.caption).foregroundColor(.green).fixedSize()
    }

    private func identityText(_ summary: ProfileIdentitySummary) -> some View {
        Text("\(L10n.text("Account", locale: locale)) \(summary.account) · \(L10n.text(summary.principalLabel, locale: locale)) \(summary.principal)")
            .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
