import Foundation
import IssueReporting
@testable import SwiftModel

/// Local subset of `Tests/SwiftModelTests/Utilities.swift` — only the helpers the
/// snapshot suites actually reference. Duplicated rather than shared because
/// SwiftPM test targets can't import other test targets, and these targets are
/// otherwise self-contained.

extension Optional where Wrapped: AnyObject {
    // Returns a closure with a weak capture so the strong reference doesn't prevent deallocation.
    var waitUntilNil: () async -> Void {
        { [weak self] in
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            while self != nil {
                if DispatchTime.now().uptimeNanoseconds > deadline {
                    reportIssue("waitUntilRemoved timed out after 5s — model was not released. Check for retain cycles.")
                    return
                }
                try? await Task.sleep(nanoseconds: 10_000_000) // poll every 10ms
            }
            // After the object is released, teardown closures dispatched during
            // onRemoval may still be held in backgroundCall's drain task queue.
            // Wait for those to finish so transitively owned objects (e.g. child
            // context References) are also released before callers assert on them.
            let idleDeadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
            await backgroundCall.waitUntilIdle(deadline: idleDeadline)
        }
    }
}

extension Model {
    func waitUntilRemoved() async {
        await context.waitUntilNil()
    }
}

extension ModelNode {
    func waitUntilRemoved() async {
        await _context.waitUntilNil()
    }
}

func waitUntilRemoved<M: Model>(_ model: () async throws -> M) async rethrows {
    try await model().context.waitUntilNil()
}
