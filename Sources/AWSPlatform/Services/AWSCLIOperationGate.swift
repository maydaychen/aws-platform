import Foundation

/// Coordinates only app-owned CLI work. Terminal sessions belong to their terminal after handoff.
final class AWSCLIOperationGate: @unchecked Sendable {
    static let shared = AWSCLIOperationGate()

    private let lock = NSLock()
    private var operations = Set<UUID>()
    private var update: UUID?

    var isUpdating: Bool {
        lock.lock()
        defer { lock.unlock() }
        return update != nil
    }

    func beginOperation() throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        guard update == nil else { throw AWSCLIUpdateError.busy }
        let token = UUID()
        operations.insert(token)
        return token
    }

    func endOperation(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        operations.remove(token)
    }

    func beginUpdate() throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        guard update == nil, operations.isEmpty else { throw AWSCLIUpdateError.busy }
        let token = UUID()
        update = token
        return token
    }

    func endUpdate(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard update == token else { return }
        update = nil
    }
}
