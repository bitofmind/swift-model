import Testing
import Foundation
import ConcurrencyExtras
@testable import SwiftModel

/// Pins the mechanism that backs `View.swiftModelDebugScope()` and
/// `ModelScope(debug:)`'s automatic env propagation: when a descendant view
/// stamps its own `ViewAccess` onto the model, reads it does through the
/// re-stamped reference register on the descendant's access — not the
/// ancestor's stamped access — even when the ancestor's reference is still in
/// scope via `accessBox._reference?.access`.
///
/// ## Background
///
/// `@ObservedModel.update()` does two things at body entry:
///
/// 1. Calls `model.withAccess(self.access)` to stamp the view's `ViewAccess`
///    onto the model value's `modelContext.access`.
/// 2. Returns the stamped value as the wrapped value the body reads through.
///
/// Reads through that stamped value flow through `Context.willAccessDirect`,
/// which resolves the active access as:
///
/// ```swift
/// let cachedActive = ModelAccess.active                                   // task-local
/// let access      = accessBox._reference?.access ?? ModelAccess.current   // stamped fallback
/// let activeAccess = cachedActive ?? access
/// ```
///
/// On iOS 17+ the lazy-install gate in `@ObservedModel.update()` normally
/// **skips** installing the descendant view's `ViewAccess` (the registrar
/// drives invalidation, the access would be pure overhead). With the install
/// skipped the descendant never re-stamps the model — its reads still flow
/// through the ancestor's stamped reference and register dependencies on the
/// ancestor's access, firing the ancestor's `$model.debug(...)` for reads
/// that originated in the descendant.
///
/// `View.swiftModelDebugScope()` (set automatically by `ModelScope(debug:)`)
/// flips the env value `\.swiftModelDebugActive = true`, which the install
/// gate then OR's into its decision. Descendants install and **re-stamp**.
/// These tests verify the re-stamping mechanism in isolation, without needing
/// a SwiftUI host — the env-driven gate decision in `update()` is an
/// integration concern covered by the example apps.
@Suite(.modelTesting(exhaustivity: .off))
struct ObservedModelDebugIsolationTests {

    /// Documents the leak: when only the ancestor stamps, descendant reads
    /// still register on the ancestor's `ViewAccess`. This is the bug the
    /// `swiftModelDebugScope()` plumbing exists to fix.
    @Test func descendantReadsLeakToAncestorWithoutRestamping() async {
        let model = ChildLeakModel().withAnchor()
        let ancestor = RecordingDebugAccess()
        let stampedForAncestor = model.withAccess(ancestor)

        // Read happens "in the descendant view body" — but the descendant
        // never re-stamped, so the read flows through the ancestor's stamp.
        _ = stampedForAncestor.child.value

        let hits = ancestor.recordedWritablePaths.value
        #expect(
            !hits.isEmpty,
            "Without restamping the leak should be present — ancestor should have seen the descendant's read."
        )
    }

    /// Fix: descendant view stamps its own access onto the model. The
    /// re-stamping replaces the `accessBox._reference?.access`, so subsequent
    /// reads register on the descendant — not the ancestor. This is the
    /// mechanism `View.swiftModelDebugScope()` activates by forcing the
    /// install gate in `@ObservedModel.update()` to install on iOS 17+.
    @Test func restampingScopesDepsToDescendant() async {
        let model = ChildLeakModel().withAnchor()
        let ancestor = RecordingDebugAccess()
        let descendant = RecordingDebugAccess()

        let stampedForAncestor = model.withAccess(ancestor)
        _ = stampedForAncestor.parentTag    // legitimate ancestor read

        // Descendant view stamps its own access onto the stamped value.
        // From here, reads register on `descendant`, not `ancestor`.
        let stampedForDescendant = stampedForAncestor.withAccess(descendant)
        _ = stampedForDescendant.child.value

        let ancestorHits = ancestor.recordedWritablePaths.value
        let descendantHits = descendant.recordedWritablePaths.value

        // Ancestor saw exactly one read — its own. The descendant's read did
        // not bleed back through the stamped chain.
        #expect(ancestorHits.count == 1, "Ancestor recorded \(ancestorHits) — expected only the parentTag read.")
        // Descendant saw at least one read — its own.
        #expect(!descendantHits.isEmpty, "Descendant recorded \(descendantHits) — expected the child.value read.")
    }

    /// Re-stamping at the descendant is independent of `usingActiveAccess`.
    /// Even if some intermediate code has called `usingActiveAccess(nil)`
    /// (which clears the task-local but NOT the stamped reference), the
    /// descendant's re-stamp still scopes its reads correctly.
    @Test func restampingWorksUnderClearedActiveAccess() async {
        let model = ChildLeakModel().withAnchor()
        let ancestor = RecordingDebugAccess()
        let descendant = RecordingDebugAccess()

        let stampedForAncestor = model.withAccess(ancestor)
        let stampedForDescendant = stampedForAncestor.withAccess(descendant)

        // Simulate code that cleared `ModelAccess.active` (e.g. memoize's
        // `usingActiveAccess(nil)` wrap) — the stamped reference is what
        // matters for descendant-scoping.
        usingActiveAccess(nil) {
            _ = stampedForDescendant.child.value
        }

        let ancestorHits = ancestor.recordedWritablePaths.value
        let descendantHits = descendant.recordedWritablePaths.value
        #expect(ancestorHits.isEmpty)
        #expect(!descendantHits.isEmpty)
    }
}

// MARK: - Test access recorder

/// Mirrors the recorder pattern from `MemoizeIsolationTests` but kept local so
/// each test file is self-contained — same shape, different test scope.
private final class RecordingDebugAccess: ModelAccess, @unchecked Sendable {
    let recordedWritablePaths = LockIsolated<[String]>([])

    init() {
        super.init(useWeakReference: false)
    }

    // `true` so reads on child models reachable through the stamped parent
    // also register on this access — that's exactly the chain we're testing.
    override var shouldPropagateToChildren: Bool { true }

    override func willAccess<M: Model, Value>(
        from context: Context<M>,
        at path: KeyPath<M._ModelState, Value> & Sendable
    ) -> (() -> Void)? {
        if path is WritableKeyPath<M._ModelState, Value> {
            recordedWritablePaths.withValue { $0.append("\(M.self).<\(Value.self)>") }
        }
        return nil
    }
}

// MARK: - Test models

@Model private struct ChildLeakModel {
    var parentTag: String = "parent"
    var child: ChildLeafModel = ChildLeafModel()
}

@Model private struct ChildLeafModel {
    var value: Int = 0
}
