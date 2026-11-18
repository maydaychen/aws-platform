import SwiftUI

struct SettingsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var settings: LanguageSettings
    @ObservedObject var updates: AppUpdateController
    @ObservedObject var transfers: TransferActivity
    @ObservedObject var cliUpdates: AWSCLIUpdateViewModel

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
            }
            Section {
                LabeledContent(L10n.text("Version", locale: locale), value: updates.version)
                Link(destination: AppUpdateController.releasesURL) {
                    Label(L10n.text("GitHub Releases", locale: locale), systemImage: "arrow.up.right.square")
                }
                .accessibilityIdentifier("github-releases-link")
            } header: {
                Label(L10n.text("Updates", locale: locale), systemImage: "arrow.down.circle")
            } footer: {
                if let updateStatus {
                    Text(L10n.text(updateStatus, locale: locale))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            AWSCLISettingsSection(updates: cliUpdates)
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 680)
    }

    private var updateStatus: String? {
        if transfers.cliMaintenanceActive {
            return "Quitting waits for the AWS CLI update to finish."
        }
        if transfers.isRestartPending {
            return "Waiting for S3 transfers to finish before quitting. New transfers are paused."
        }
        return nil
    }
}
