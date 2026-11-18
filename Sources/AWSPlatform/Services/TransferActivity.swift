import Foundation

/// Process-wide leases outlive cancelled or invalidated views and protect app termination.
@MainActor
final class TransferActivity: ObservableObject {
    static let shared = TransferActivity()

    @Published private(set) var activeCount = 0
    @Published private(set) var cliMaintenanceActive = false
    @Published private(set) var isRestartPending = false
    private var leases = Set<UUID>()
    private var cliMaintenanceLease: UUID?
    private var terminationHandler: (() -> Void)?

    func begin() -> UUID? {
        guard !isRestartPending, !cliMaintenanceActive else { return nil }
        let lease = UUID()
        leases.insert(lease)
        activeCount = leases.count
        return lease
    }

    func finish(_ lease: UUID) {
        guard leases.remove(lease) != nil else { return }
        activeCount = leases.count
        resumeWhenIdle()
    }

    func beginCLIMaintenance() -> UUID? {
        guard leases.isEmpty, !isRestartPending, cliMaintenanceLease == nil else { return nil }
        let lease = UUID()
        cliMaintenanceLease = lease
        cliMaintenanceActive = true
        return lease
    }

    func finishCLIMaintenance(_ lease: UUID) {
        guard cliMaintenanceLease == lease else { return }
        cliMaintenanceLease = nil
        cliMaintenanceActive = false
        resumeWhenIdle()
    }

    private var hasActivity: Bool { !leases.isEmpty || cliMaintenanceLease != nil }

    private func resumeWhenIdle() {
        guard !hasActivity else { return }
        let termination = terminationHandler
        terminationHandler = nil
        isRestartPending = false
        termination?()
    }

    func postponeTermination(_ reply: @escaping () -> Void) -> Bool {
        guard hasActivity else { return false }
        isRestartPending = true
        if terminationHandler == nil { terminationHandler = reply }
        return true
    }
}
