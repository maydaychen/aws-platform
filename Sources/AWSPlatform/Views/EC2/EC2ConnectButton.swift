import SwiftUI

@MainActor
struct EC2ConnectButton: View {
    @Environment(\.locale) private var locale
    let instance: EC2InstanceModel
    let scope: MonitoringScope?
    let isCurrentSelection: Bool
    var service = EC2SSMConnectionService()
    @State private var error: EC2SSMConnectionError?

    var request: EC2SSMConnectionRequest? {
        guard isCurrentSelection else { return nil }
        return try? EC2SSMConnectionRequest(scope: scope, instance: instance)
    }

    var body: some View {
        Button(action: connect) {
            Label(L10n.text("Connect", locale: locale), systemImage: "terminal")
        }
        .disabled(request == nil)
        .help(L10n.text(request != nil ? "Open an SSM session in your default terminal" :
            (instance.state != "running" ? EC2SSMConnectionError.notRunning.rawValue : EC2SSMConnectionError.invalidScope.rawValue), locale: locale))
        .accessibilityIdentifier("ec2.connect")
        .alert(L10n.text("Unable to connect", locale: locale), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button(L10n.text("OK", locale: locale)) { error = nil }
        } message: {
            Text(L10n.text(error?.rawValue ?? "", locale: locale))
        }
        .onChange(of: scope) { _ in error = nil }
        .onChange(of: instance.instanceId) { _ in error = nil }
    }

    private func connect() {
        guard let request else { return }
        do { try service.connect(request, locale: locale) }
        catch let failure as EC2SSMConnectionError { error = failure }
        catch { self.error = .prepareFailed }
    }
}
