import SwiftUI

struct EC2HealthStatusIndicator: View {
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let health: EC2InstanceHealth?
    let isLoading: Bool
    let error: String?

    var body: some View {
        if isLoading {
            EC2HealthLoadingIndicator(reduceMotion: reduceMotion)
        } else if health?.needsAttention == true {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .help(attentionDescription)
                .accessibilityLabel(L10n.text(health?.summary ?? "Needs attention", locale: locale))
                .accessibilityValue(attentionDescription)
        } else if error == nil, health?.summary == "Checks passed" {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .help(L10n.text("Status checks passed", locale: locale))
                .accessibilityLabel(L10n.text("Status checks passed", locale: locale))
        } else if error == nil, health?.isNotApplicable == true {
            Image(systemName: "minus.circle")
                .foregroundColor(.secondary)
                .help(L10n.text("Status checks not applicable", locale: locale))
                .accessibilityLabel(L10n.text("Status checks not applicable", locale: locale))
        } else {
            Image(systemName: "questionmark.circle.fill")
                .foregroundColor(.orange)
                .help(L10n.format("Status checks: %@", L10n.text(error ?? "Status checks were not returned for this instance.", locale: locale), locale: locale))
                .accessibilityLabel(L10n.text("Unable to read status checks", locale: locale))
                .accessibilityValue(L10n.text(error ?? "Status checks were not returned for this instance.", locale: locale))
        }
    }

    private var attentionDescription: String {
        let summary = L10n.text(health?.summary ?? "Needs attention", locale: locale)
        return error.map { summary + "\n" + L10n.text($0, locale: locale) } ?? summary
    }
}

struct EC2HealthLoadingIndicator: View {
    @Environment(\.locale) private var locale
    let reduceMotion: Bool

    var body: some View {
        Group {
            if reduceMotion {
                Image(systemName: "clock").foregroundColor(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .help(L10n.text("Loading status checks…", locale: locale))
        .accessibilityLabel(L10n.text("Loading status checks…", locale: locale))
    }
}

struct EC2HealthReadWarning: View {
    @Environment(\.locale) private var locale
    let errors: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(errors.count == 1
                  ? L10n.text("Status checks could not be read for 1 instance.", locale: locale)
                  : L10n.format("Status checks could not be read for %@ instances.", String(errors.count), locale: locale),
                  systemImage: "questionmark.circle.fill")
                .foregroundColor(.orange)
            if let error = errors.sorted(by: { $0.key < $1.key }).first?.value {
                Text(L10n.text(error, locale: locale)).textSelection(.enabled)
            }
            Text(L10n.text("Refresh the list to retry status checks.", locale: locale))
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
