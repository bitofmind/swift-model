import Testing
@testable import SwiftModel
import Foundation

// Regression tests for the race between Reference.clear() and concurrent
// Context.subscript._read. clear() swaps reference.state under Reference.lock
// while reads hold the separate AnyContext.lock — two independent locks that
// allowed concurrent access to the same memory. For a large _State struct
// (containing class references), this produced torn reads where swift_retain
// was called on garbage pointers → EXC_BAD_ACCESS (KERN_PROTECTION_FAILURE).
//
// The fix: clear() now re-acquires AnyContext.lock before touching state
// (lock order: AnyContext.lock → Reference.lock, the same order used by
// destruct() in the same onRemoval path), blocking concurrent reads.
//
// Without TSan these tests need many iterations to surface the race.
// With TSan enabled, a single iteration reliably catches unsynchronized access.
struct ClearRaceTests {

    // Tests that releasing a model anchor while a detached task concurrently reads
    // a child @Model property does not produce a torn read / use-after-free crash.
    //
    // Stack trace from the production crash:
    //   swift_retain ← initializeWithCopy for <ChildModel> ←
    //   Context.subscript.read ← _ModelSourceBox.subscript.read ←
    //   <property getter> ← <model task body>
    @Test func clearDoesNotRaceWithConcurrentChildRead() async {
        // With TSan enabled, a single iteration reliably catches the data race.
        // A small number of iterations gives probabilistic coverage without TSan.
        for _ in 0..<20 {
            let (parent, anchor) = ClearRaceParent().returningAnchor()

            // Detached task reads the child property on a separate cooperative thread,
            // creating genuine concurrency with the anchor release below. It is not a
            // model task, so it is NOT cancelled by context.onRemoval()'s cancelAll().
            let reader = Task.detached {
                for _ in 0..<100 {
                    _ = parent.child
                }
            }

            // Release the anchor: ModelAnchor.deinit → context.onRemoval()
            //   1. lock { marks context destructed; appends clear() to callbacks }
            //   2. lock released
            //   3. callbacks run — clear() fires here
            //
            // Without the fix, step 3 modifies reference.state under Reference.lock
            // only, racing with the reader which holds AnyContext.lock during its copy.
            withExtendedLifetime(anchor) {}

            await reader.value
        }
    }
}

// Models must be file-private (not nested inside the test struct) so that the
// @Model macro can generate the required extensions.

@Model private struct ClearRaceParent {
    var child: ClearRaceChild = ClearRaceChild()
}

@Model private struct ClearRaceChild {
    var value: Int = 0
}
