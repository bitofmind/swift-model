#if canImport(Dispatch)
import Foundation
import Testing
@testable import SwiftModel

/// `require` must take its verdict from the executor drive, as `expect` does,
/// not from the 5 s × scale wall-clock budget.
///
/// On the saturated macOS TSan runner `taskWriteOfContainerPropertyIsAssertedByRequire`
/// failed with "Failed to unwrap" after exactly its 30 s budget (5 s × scale 6):
/// the activation task that writes the value had not been scheduled yet. Here
/// the writer is busy for longer than a shrunken budget instead, so the old
/// wall-clock verdict fails deterministically and the drive's verdict (the
/// writer's job is still running, so the model isn't quiescent) waits it out.
@Test(.modelTesting) func requireWaitsForABusyWriterPastTheBudget() async throws {
    guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
    try await TestAccessOverrides.$hardCapNanoseconds.withValue(50_000_000) {
        let model = SlowWriterModel().withAnchor()
        let value = try await require(model.value)
        #expect(value == 1)
    }
}

/// The other half of the verdict: a `require` that can never be met still fails,
/// at the drive's fixpoint, instead of waiting out the far-out hang deadline.
@Test(.modelTesting) func requireFailsAtFixpointWhenNeverMet() async {
    let model = SlowWriterModel(writes: false).withAnchor()
    await withKnownIssue {
        _ = try await require(model.value)
    }
}

@Model private struct SlowWriterModel {
    var value: Int? = nil
    var writes = true

    func onActivate() {
        guard writes else { return }
        node.task {
            // Busy, not parked: a running job keeps the drive from reaching a
            // fixpoint, so only a wall-clock budget could fail this wait.
            blockThread(seconds: 0.3)
            value = 1
        }
    }
}

/// Synchronous so it can block from inside the async task body.
private func blockThread(seconds: Double) {
    Thread.sleep(forTimeInterval: seconds)
}
#endif
