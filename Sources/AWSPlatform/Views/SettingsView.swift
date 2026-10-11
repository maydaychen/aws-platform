import SwiftUI

struct SettingsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var settings: LanguageSettings
    @ObservedObject var updates: AppUpdateController
    @ObservedObject var transfers: TransferActivity

    var body: some View {
        Form {
            Section {
                Picker(L10n.text("Language", locale: locale), selection: $settings.selection) {
                    Text(L10n.text("Follow System", locale: locale)).tag(AppLanguage.system)
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                    Text(verbatim: "English").tag(AppLanguage.english)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("app-language")
            } header: {
                Label(L10n.text("Appearance", locale: locale), systemImage: "globe")
            } footer: {
                Text(L10n.text("Language changes apply immediately to all windows. AWS service names, resource names, identifiers, tags, logs and event descriptions stay in their original language.", locale: locale))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent(L10n.text("Version", locale: locale), value: updates.version)
                Toggle(L10n.text("Automatically check for updates", locale: locale), isOn: Binding(
                    get: { updates.automaticallyChecks }, set: { updates.setAutomaticallyChecks($0) }
                ))
                .disabled(updates.unavailable)
                Button(L10n.text("Check for Updates…", locale: locale)) { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
                    .accessibilityIdentifier("check-for-updates")
            } header: {
                Label(L10n.text("Updates", locale: locale), systemImage: "arrow.down.circle")
            } footer: {
                Text(L10n.text(updateExplanation, locale: locale))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
    }

    private var updateExplanation: String {
        if updates.unavailable { return "Update checks are available in packaged applications." }
        if transfers.isRestartPending {
            return "Waiting for S3 transfers to finish before restarting. New transfers are paused."
        }
        return "Updates use GitHub. Installation requires your confirmation and waits for S3 transfers to finish."
    }
}
