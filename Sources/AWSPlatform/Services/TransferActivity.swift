import Foundation

/// Process-wide leases outlive cancelled or invalidated S3 view models.
@MainActor
final class TransferActivity: ObservableObject {
    enum UpdateStage { case idle, postponed, installing }
    static let shared = TransferActivity()

    @Published private(set) var activeCount = 0
    @Published private(set) var isRestartPending = false
    private(set) var updateStage = UpdateStage.idle
    private var leases = Set<UUID>()
    private var updateHandler: (() -> Void)?
    private var terminationHandler: (() -> Void)?

    func begin() -> UUID? {
        guard !isRestartPending else { return nil }
        let lease = UUID()
        leases.insert(lease)
        activeCount = leases.count
        return lease
    }

    func finish(_ lease: UUID) {
        guard leases.remove(lease) != nil else { return }
        activeCount = leases.count
        guard leases.isEmpty else { return }
        let update = updateHandler
        let termination = terminationHandler
        updateHandler = nil
        terminationHandler = nil
        update?()
        termination?()
    }

    func postponeUpdate(_ install: @escaping () -> Void) -> Bool {
        updateStage = .postponed
        isRestartPending = true
        guard !leases.isEmpty else { return false }
        if updateHandler == nil { updateHandler = install }
        return true
    }

    func postponeTermination(_ reply: @escaping () -> Void) -> Bool {
        guard !leases.isEmpty else { return false }
        isRestartPending = true
        if terminationHandler == nil { terminationHandler = reply }
        return true
    }

    func cancelUpdate() {
        updateStage = .idle
        updateHandler = nil
        // A pending application quit still needs its termination reply.
        isRestartPending = terminationHandler != nil
    }

    func markUpdateInstallation() {
        updateStage = .installing
        isRestartPending = true
    }

    func finishUpdateCycle(hasError: Bool) {
        // A successful installation also ends the check cycle before app termination.
        if hasError || updateStage != .installing { cancelUpdate() }
    }
}
