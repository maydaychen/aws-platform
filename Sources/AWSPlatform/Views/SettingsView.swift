import SwiftUI

struct SettingsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var settings: LanguageSettings

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
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 220)
    }
}
