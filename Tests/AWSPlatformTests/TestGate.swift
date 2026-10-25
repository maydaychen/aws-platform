import Foundation

/// Holds a mock response even when its caller is cancelled.
actor TestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var entered = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters = []
        }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
