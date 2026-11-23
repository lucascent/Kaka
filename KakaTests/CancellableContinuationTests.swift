import Foundation
import Synchronization
import Testing
@testable import Kaka

struct CancellableContinuationTests {
    @Test func callbackBeforeContinuationIsInstalled() async throws {
        let bridge = CancellableContinuation<Int>()
        bridge.resolve(.success(42))
        let value = try await withCheckedThrowingContinuation { bridge.install($0) }
        #expect(value == 42)
    }

    @Test func cancellationBeforeRequestIDCancelsTheRegisteredRequest() async {
        let bridge = CancellableContinuation<Int>()
        let cancellationCount = Mutex(0)
        bridge.cancel()
        bridge.setCancellation { cancellationCount.withLock { $0 += 1 } }
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { bridge.install($0) }
        }
        #expect(cancellationCount.withLock { $0 } == 1)
    }

    @Test func repeatedCallbacksAndCancellationDoNotReplaceSuccess() async throws {
        let bridge = CancellableContinuation<Int>()
        bridge.resolve(.success(7))
        bridge.resolve(.success(8))
        bridge.cancel()
        let value = try await withCheckedThrowingContinuation { bridge.install($0) }
        #expect(value == 7)
    }

    @Test func cancellationAndCallbackRaceResumesOnce() async {
        for _ in 0..<50 {
            let bridge = CancellableContinuation<Int>()
            let value = await withTaskGroup(of: Void.self, returning: Int?.self) { group in
                group.addTask { bridge.cancel() }
                group.addTask { bridge.resolve(.success(1)) }
                return try? await withCheckedThrowingContinuation { bridge.install($0) }
            }
            #expect(value == nil || value == 1)
        }
    }
}
