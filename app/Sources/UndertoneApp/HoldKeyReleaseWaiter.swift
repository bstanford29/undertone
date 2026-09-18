import Foundation

/// Waits for a release signal (typically `HotkeyMonitor.onHoldKeyReleased`)
/// or a timeout, whichever comes first. Kept as a free function independent
/// of `AppModel` and `HotkeyMonitor` so it can be driven by a fake clock in
/// tests, with no real delay and no dependency on a running event tap.
enum HoldKeyReleaseWaiter {
    /// Registers for the release signal via `registerSignal`, which is
    /// handed a closure to call when release happens, then waits for either
    /// that call or `sleep(timeout)` to complete. Resumes exactly once no
    /// matter which fires first, and no matter how many times the signal
    /// closure is invoked.
    static func wait(
        timeout: Duration,
        registerSignal: @Sendable (@escaping @Sendable () -> Void) -> Void,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumer = SingleResume(continuation)
            registerSignal { resumer.resume() }
            Task {
                await sleep(timeout)
                resumer.resume()
            }
        }
    }
}

/// Resumes a `CheckedContinuation` exactly once even when two concurrent
/// sources (the release signal and the timeout) race to complete it.
private final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume()
    }
}
