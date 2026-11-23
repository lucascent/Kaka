import Foundation
import Synchronization

/// Bridges callback APIs without double-resuming when cancellation races a callback.
/// The lock also covers cancellation that happens before a request ID is available.
nonisolated final class CancellableContinuation<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var result: Result<Value, any Error>?
        var cancellation: (@Sendable () -> Void)?
        var isCancelled = false
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let result = state.withLock { state -> Result<Value, any Error>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func setCancellation(_ cancellation: @escaping @Sendable () -> Void) {
        let shouldCancel = state.withLock { state in
            if state.isCancelled { return true }
            if state.result == nil { state.cancellation = cancellation }
            return false
        }
        if shouldCancel { cancellation() }
    }

    func resolve(_ result: Result<Value, any Error>) {
        let continuation = state.withLock { state in
            guard state.result == nil else { return nil as CheckedContinuation<Value, any Error>? }
            state.result = result
            state.cancellation = nil
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    func cancel(throwing error: any Error = CancellationError()) {
        let action = state.withLock { state -> (CheckedContinuation<Value, any Error>?, (@Sendable () -> Void)?) in
            guard state.result == nil else { return (nil, nil) }
            state.isCancelled = true
            state.result = .failure(error)
            let action = (state.continuation, state.cancellation)
            state.continuation = nil
            state.cancellation = nil
            return action
        }
        action.1?()
        action.0?.resume(throwing: error)
    }
}
