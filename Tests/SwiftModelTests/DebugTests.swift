import Testing
import InlineSnapshotTesting
import ConcurrencyExtras
import Observation
@testable import SwiftModel

// MARK: - Test models

@Model struct DebugCounter {
    var count: Int = 0
    var name: String = "default"

    var doubled: Int {
        node.memoize(for: "doubled") { count * 2 }
    }

    var doubledEquatable: Int {
        node.memoize(for: "doubledEq") { count * 2 }
    }
}

@Model struct DebugParent {
    var child = DebugCounter()
    var tag: String = "parent"
}

@Model struct DebugDualParent {
    var a = DebugCounter()
    var b = DebugCounter()
}

@Model struct DebugOptionalParent {
    var child: DebugCounter? = nil
}

@Model struct DebugSwapParent {
    var first = DebugCounter()
    var second = DebugCounter()
    var useSecond = false

    var active: DebugCounter {
        get { useSecond ? second : first }
        set { if useSecond { second = newValue } else { first = newValue } }
    }
}

// MARK: - Output capture helper

/// A `TextOutputStream` that accumulates writes into a `LockIsolated` string.
final class CaptureStream: TextOutputStream, @unchecked Sendable {
    let buffer = LockIsolated("")

    func write(_ string: String) {
        buffer.withValue { $0 += string + "\n" }
    }

    var captured: String { buffer.value }

    func reset() { buffer.setValue("") }
}

// MARK: - assertOutputSnapshot helper

/// Runs `build(output)`, polls until `predicate(output.captured)` is true, then asserts
/// the captured output matches the inline snapshot.
///
/// The `until:` predicate is re-evaluated on every poll iteration, so it always sees
/// the latest output. This eliminates the need for a separate `try await waitUntil(…)`
/// call and for returning the model just to drive `waitUntilRemoved`.
///
/// ```swift
/// @Test func myDebugTest() async throws {
///     try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
///         let model = DebugCounter().withAnchor()
///         model.debug([.changes(), .name("Counter"), .printer(output)])
///         model.value = 42
///     } result: {
///         """
///         Counter value changed:
///         ...
///         """
///     }
/// }
/// ```
func assertOutputSnapshot(
    until predicate: @escaping @Sendable (String) -> Bool,
    fileID: StaticString = #fileID,
    file: StaticString = #filePath,
    function: StaticString = #function,
    line: UInt = #line,
    column: UInt = #column,
    _ build: (CaptureStream) async throws -> Void,
    result expected: (() -> String)? = nil
) async throws {
    let output = CaptureStream()
    try await build(output)
    try await waitUntil(predicate(output.captured))
    assertInlineSnapshot(
        of: output.captured,
        as: .lines,
        matches: expected,
        fileID: fileID,
        file: file,
        function: function,
        line: line,
        column: column
    )
}

// MARK: - Tests

struct DebugTests {

    // MARK: node.debug() — changes (diff)

    @Test func debugWholeSubtree_diff() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter().withAnchor()
            model.debug([.changes(), .name("Counter"), .printer(output)])
            model.count = 1
        } result: {
            """
            Counter value changed:
              DebugCounter(
            -   count: 0,
            +   count: 1,
                name: "default"
              )

            """
        }
    }

    // MARK: node.debug() — child model changes fire on parent

    /// Regression test: the no-closure `debug()` must detect changes in child models,
    /// not just top-level properties on the observed model.
    @Test func debugWholeSubtree_childModel() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Parent") }) { output in
            let parent = DebugParent().withAnchor()
            parent.debug([.changes(), .name("Parent"), .printer(output)])
            parent.child.count = 5
        } result: {
            """
            Parent value changed:
              DebugParent(
                child: DebugCounter(
            -     count: 0,
            +     count: 5,
                  name: "default"
                ),
                tag: "parent"
              )

            """
        }
    }

    // MARK: node.debug() — changes (value)

    @Test func debugWholeSubtree_value() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter().withAnchor()
            model.debug([.changes(.value), .name("Counter"), .printer(output)])
            model.count = 42
        } result: {
            """
            Counter = DebugCounter(
              count: 42,
              name: "default"
            )

            """
        }
    }

    // MARK: node.debug { } — targeted with triggers

    @Test func debugTargeted_triggers_name() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter().withAnchor()
            model.debug([.triggers(), .name("Counter"), .printer(output)]) { model.count }
            model.count = 5
        } result: {
            """
            Counter triggered update:
              dependency changed: DebugCounter.count

            """
        }
    }

    @Test func debugTargeted_triggers_withValue() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter().withAnchor()
            model.debug([.triggers(.withValue), .name("Counter"), .printer(output)]) { model.count }
            model.count = 7
        } result: {
            """
            Counter triggered update:
              dependency changed: DebugCounter.count: 0 → 7

            """
        }
    }

    /// Each trigger should show the value at the time of the *previous* trigger as the old value,
    /// not the value at subscription time. This verifies the rolling-update behaviour.
    @Test func debugTargeted_triggers_withValue_consecutive() async throws {
        let output = CaptureStream()
        let model = DebugCounter().withAnchor()
        model.debug([.triggers(.withValue), .name("Counter"), .printer(output)]) { model.count }

        model.count = 7
        try await waitUntil(output.captured.contains("Counter"))
        output.reset()

        model.count = 12
        try await waitUntil(output.captured.contains("Counter"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            Counter triggered update:
              dependency changed: DebugCounter.count: 7 → 12

            """
        }
    }

    /// `.withValue` uses `customDumping` for the old/new representation, so `String`
    /// values appear with their surrounding quotes — making the output unambiguous.
    @Test func debugTargeted_triggers_withValue_string() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter().withAnchor()
            model.debug([.triggers(.withValue), .name("Counter"), .printer(output)]) { model.name }
            model.name = "Alice"
        } result: {
            """
            Counter triggered update:
              dependency changed: DebugCounter.name: "default" → "Alice"

            """
        }
    }

    @Test func debugTargeted_triggersAndChanges() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter().withAnchor()
            model.debug([.triggers(), .changes(), .name("Counter"), .printer(output)]) { model.count }
            model.count = 3
        } result: {
            """
            Counter triggered update:
              dependency changed: DebugCounter.count
            Counter value changed:
            - 0
            + 3

            """
        }
    }

    // MARK: node.debug { } — default label (no .name())

    /// When no `.name()` option is provided, the model type name is used as the label.
    /// This applies to both the no-closure and closure forms.
    @Test func debugTargeted_triggers_defaultName() async throws {
        try await assertOutputSnapshot(until: { $0.contains("DebugCounter") }) { output in
            let model = DebugCounter().withAnchor()
            model.debug([.triggers(), .printer(output)]) { model.count }  // no .name()
            model.count = 1
        } result: {
            """
            DebugCounter triggered update:
              dependency changed: DebugCounter.count

            """
        }
    }

    // MARK: memoize(debug:)

    @Test func memoizeDebug_triggersAndChanges() async throws {
        try await assertOutputSnapshot(until: { $0.contains("debugDoubled") }) { output in
            let debugOpts: DebugOptions = [.triggers(.name), .changes(.value), .printer(output)]
            let model = DebugCounter().withAnchor()
            _ = model.node.memoize(for: "debugDoubled", debug: debugOpts, produce: { model.count * 2 })
            model.count = 5
        } result: {
            """
            DebugCounter[memoize: "debugDoubled"] triggered update:
              dependency changed: DebugCounter.count
            DebugCounter[memoize: "debugDoubled"] = 10

            """
        }
    }

    // MARK: Observed(debug:)

    // Note: Observed tests use waitUntilRemoved to keep the model alive until the
    // forEach delivery completes — the model must not be deallocated before the async
    // stream delivers values (which would cancel the forEach task).

    @Test func observedDebug_triggers() async throws {
        let received = LockIsolated<[Int]>([])
        let output = CaptureStream()

        try await waitUntilRemoved {
            let model = DebugCounter()
                .withActivation { model in
                    model.node.forEach(Observed(debug: [.triggers(.name), .name("ObsCounter"), .printer(output)]) { model.count }) { value in
                        received.withValue { $0.append(value) }
                    }
                }
                .withAnchor()
            model.count = 9
            try await waitUntil(received.value.contains(9))
            return model
        }

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            ObsCounter triggered update:
              dependency changed: DebugCounter.count

            """
        }
        #expect(received.value.contains(9))
    }

    // MARK: node.debug { } — closure returns model directly (subscribeToReturnedModels path)

    /// When the debug closure returns `model` itself no property reads are recorded by
    /// withObservationTracking / AccessCollector, so `subscribeToReturnedModels` must
    /// subscribe via `onAnyModification` and bypass `isSame` to fire the update.
    @Test func debugTargeted_changes_selfReturn() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter().withAnchor()
            model.debug([.changes(), .name("Counter"), .printer(output)]) { model }
            model.count = 4
        } result: {
            """
            Counter value changed:
              DebugCounter(
            -   count: 0,
            +   count: 4,
                name: "default"
              )

            """
        }
    }

    /// Same as above but the closure returns a child model from a parent — mutations on
    /// the child should fire the debug output even though no properties were read.
    @Test func debugTargeted_changes_childReturn() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Child") }) { output in
            let parent = DebugParent().withAnchor()
            parent.debug([.changes(), .name("Child"), .printer(output)]) { parent.child }
            parent.child.count = 7
        } result: {
            """
            Child value changed:
              DebugCounter(
            -   count: 0,
            +   count: 7,
                name: "default"
              )

            """
        }
    }

    // MARK: withDebug modifier

    @Test func withDebug_modifier() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter()
                .withDebug([.changes(), .name("Counter"), .printer(output)])
                .withAnchor()
            model.count = 11
        } result: {
            """
            Counter value changed:
              DebugCounter(
            -   count: 0,
            +   count: 11,
                name: "default"
              )

            """
        }
    }

    // MARK: node.debug { } — closure returns tuple, optional, array, swapped model

    /// When the debug closure returns a tuple of two models directly, mutations on
    /// either model should fire debug output via `subscribeToReturnedModels`.
    /// Unchanged elements appear as context; only the mutated field shows a diff line.
    @Test func debugTargeted_changes_tupleReturn() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Dual") }) { output in
            let parent = DebugDualParent().withAnchor()
            parent.debug([.changes(), .name("Dual"), .printer(output)]) { (parent.a, parent.b) }
            parent.a.count = 3
        } result: {
            """
            Dual value changed:
              (
                DebugCounter(
            -     count: 0,
            +     count: 3,
                  name: "default"
                ),
                DebugCounter(
                  count: 0,
                  name: "default"
                )
              )

            """
        }
    }

    /// When the debug closure returns an optional model directly, mutations on the
    /// wrapped model should fire debug output via `subscribeToReturnedModels`.
    @Test func debugTargeted_changes_optionalReturn() async throws {
        let output = CaptureStream()
        let parent = DebugOptionalParent().withAnchor()
        parent.debug([.changes(), .name("Opt"), .printer(output)]) { parent.child }

        // nil → some: assigning a new model should show the full model appearing
        parent.child = DebugCounter()
        try await waitUntil(output.captured.contains("Opt"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            Opt value changed:
            - nil
            + DebugCounter(
            +   count: 0,
            +   name: "default"
            + )

            """
        }
        output.reset()

        // some mutation: mutating the wrapped model should show a diff
        parent.child!.count = 5

        try await waitUntil(output.captured.contains("Opt"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            Opt value changed:
              DebugCounter(
            -   count: 0,
            +   count: 5,
                name: "default"
              )

            """
        }
    }

    /// When the debug closure returns an array of models directly, mutations on any
    /// element should fire debug output via `subscribeToReturnedModels`.
    /// Unchanged elements appear as context; only the mutated field shows a diff line.
    @Test func debugTargeted_changes_arrayReturn() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Arr") }) { output in
            let parent = DebugDualParent().withAnchor()
            parent.debug([.changes(), .name("Arr"), .printer(output)]) { [parent.a, parent.b] }
            parent.b.count = 7
        } result: {
            """
            Arr value changed:
              [
                [0]: DebugCounter(
                  count: 0,
                  name: "default"
                ),
                [1]: DebugCounter(
            -     count: 0,
            +     count: 7,
                  name: "default"
                )
              ]

            """
        }
    }

    /// When the debug closure returns a different model instance after a swap, the
    /// observer should re-subscribe to the new model and fire on its mutations.
    @Test func debugTargeted_changes_swapReturn() async throws {
        let output = CaptureStream()
        let parent = DebugSwapParent().withAnchor()
        parent.debug([.changes(), .name("Swap"), .printer(output)]) { parent.active }

        // Phase 1: Mutate first child
        parent.active.count = 5
        try await waitUntil(output.captured.contains("Swap"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            Swap value changed:
              DebugCounter(
            -   count: 0,
            +   count: 5,
                name: "default"
              )

            """
        }
        output.reset()

        // Phase 2: Swap to second child — previous=first(count=5), new=second(count=0)
        parent.useSecond = true
        try await waitUntil(output.captured.contains("Swap"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            Swap value changed:
              DebugCounter(
            -   count: 5,
            +   count: 0,
                name: "default"
              )

            """
        }
        output.reset()

        // Phase 3: Mutate new active child — should fire against the new model
        parent.active.count = 9
        try await waitUntil(output.captured.contains("Swap"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            Swap value changed:
              DebugCounter(
            -   count: 0,
            +   count: 9,
                name: "default"
              )

            """
        }
    }

    /// Only properties read inside the closure are tracked as dependencies.
    /// Mutating an unrelated child property does not fire the debug output.
    @Test func debugTargeted_tracksOnlyAccessedProperties() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Observer") }) { output in
            let parent = DebugParent().withAnchor()
            parent.debug([.triggers(), .changes(), .name("Observer"), .printer(output)]) { parent.tag }
            parent.child.count = 99   // not in the closure — should not trigger
            parent.tag = "updated"
        } result: {
            """
            Observer triggered update:
              dependency changed: DebugParent.tag
            Observer value changed:
            - "parent"
            + "updated"

            """
        }
    }

    // MARK: .shallow — no-closure form

    /// `.shallow` in the no-closure form: mutations inside child models do not produce
    /// any diff output. The root model's own property changes still appear, but child
    /// models are rendered as an opaque type name (hiding their internals).
    ///
    /// Both mutations happen before the wait so no sleep is needed — if the child change
    /// had incorrectly produced output, the snapshot would contain an extra block and fail.
    @Test func debugShallow_noClosureForm_childChangesIgnored() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Parent") }) { output in
            let parent = DebugParent().withAnchor()
            parent.debug([.changes(), .shallow, .name("Parent"), .printer(output)])
            parent.child.count = 99  // child change — shallow snapshot hides internals → no diff
            parent.tag = "updated"   // root property change — should appear in the diff
        } result: {
            """
            Parent value changed:
              DebugParent(
                child: DebugCounter(),
            -   tag: "parent"
            +   tag: "updated"
              )

            """
        }
    }

    // MARK: .shallow — closure form

    /// `.shallow` in the closure form: child model property accesses are not tracked
    /// by the debug collector, so mutations to child properties don't produce trigger
    /// output. Root model properties in the closure are still tracked normally.
    ///
    /// Both mutations happen before the wait — if the child change had incorrectly
    /// triggered output, the snapshot would contain `DebugCounter.count` and fail.
    @Test func debugShallow_closureForm_childNotTrackedAsTrigger() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Parent") }) { output in
            let parent = DebugParent().withAnchor()
            // Closure reads both a root property and a child property.
            parent.debug([.triggers(), .shallow, .name("Parent"), .printer(output)]) {
                "\(parent.tag) \(parent.child.count)"
            }
            parent.child.count = 5  // child property — NOT tracked by shallow debug collector
            parent.tag = "updated"  // root property — IS tracked
        } result: {
            """
            Parent triggered update:
              dependency changed: DebugParent.tag

            """
        }
    }

    /// When the closure reads a child model property, changes to that property do fire.
    @Test func debugTargeted_tracksChildProperties() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Parent") }) { output in
            let parent = DebugParent().withAnchor()
            parent.debug([.triggers(), .name("Parent"), .printer(output)]) { parent.child.count }
            parent.child.count = 5
        } result: {
            """
            Parent triggered update:
              dependency changed: DebugCounter.count

            """
        }
    }

    // MARK: Default label (no .name())

    /// When no `.name()` option is provided, the type name is used as the label.
    @Test func debugWholeSubtree_diff_defaultName() async throws {
        try await assertOutputSnapshot(until: { $0.contains("DebugCounter") }) { output in
            let model = DebugCounter().withAnchor()
            model.debug([.changes(), .printer(output)])  // no .name()
            model.count = 1
        } result: {
            """
            DebugCounter value changed:
              DebugCounter(
            -   count: 0,
            +   count: 1,
                name: "default"
              )

            """
        }
    }

    // MARK: Closure form with .changes(.value)

    /// The `.changes(.value)` format prints only the new value (no diff) for the
    /// closure form, where `T` is a plain `Int` rather than the whole model struct.
    @Test func debugTargeted_changes_value_closureForm() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter().withAnchor()
            model.debug([.changes(.value), .name("Counter"), .printer(output)]) { model.count }
            model.count = 42
        } result: {
            """
            Counter = 42

            """
        }
    }

    // MARK: Observed(debug:) with both triggers and changes

    @Test func observedDebug_triggersAndChanges() async throws {
        let received = LockIsolated<[Int]>([])
        let output = CaptureStream()

        try await waitUntilRemoved {
            let model = DebugCounter()
                .withActivation { model in
                    model.node.forEach(Observed(debug: [.triggers(.name), .changes(), .name("ObsCounter"), .printer(output)]) { model.count }) { value in
                        received.withValue { $0.append(value) }
                    }
                }
                .withAnchor()
            model.count = 9
            try await waitUntil(received.value.contains(9))
            return model
        }

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            ObsCounter triggered update:
              dependency changed: DebugCounter.count
            ObsCounter value changed:
            - 0
            + 9

            """
        }
    }

    // MARK: Memoize debug variants

    /// When `memoize` is called without an explicit string key, `FileAndLine` is used as
    /// the cache key. Its `description` is `"filename.swift:line"`, so the debug label
    /// becomes `ModelType[memoize: "filename.swift:line"]`.
    ///
    /// This test synthesises a fixed `FileAndLine` value (using string literals, which are
    /// valid `StaticString` initialisers) so the snapshot stays stable even as lines shift.
    @Test func memoizeDebug_implicitKey_fileAndLine() async throws {
        try await assertOutputSnapshot(until: { $0.contains("DebugCounter") }) { output in
            let debugOpts: DebugOptions = [.triggers(.name), .changes(.value), .printer(output)]
            let model = DebugCounter().withAnchor()
            let key = FileAndLine(fileID: "DebugCounter.swift", filePath: "DebugCounter.swift", line: 42, column: 1)
            _ = model.node.memoize(for: key, debug: debugOpts, produce: { model.count * 2 })
            model.count = 5
        } result: {
            """
            DebugCounter[memoize: "DebugCounter.swift:42"] triggered update:
              dependency changed: DebugCounter.count
            DebugCounter[memoize: "DebugCounter.swift:42"] = 10

            """
        }
    }

    /// `.name()` overrides the auto-generated `ModelType[memoize: "key"]` label.
    @Test func memoizeDebug_customName() async throws {
        try await assertOutputSnapshot(until: { $0.contains("myComputed") }) { output in
            let debugOpts: DebugOptions = [.triggers, .name("myComputed"), .printer(output)]
            let model = DebugCounter().withAnchor()
            _ = model.node.memoize(for: "debugDoubled", debug: debugOpts, produce: { model.count * 2 })
            model.count = 3
        } result: {
            """
            myComputed triggered update:
              dependency changed: DebugCounter.count

            """
        }
    }

    /// `.triggers(.withDiff)` shows a structured `−`/`+` diff of each dependency's value.
    /// For primitive values the diff shows old/new lines; for model-typed values the full
    /// sub-property tree is expanded so the exact change is visible.
    @Test func debugTargeted_triggers_withDiff() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter().withAnchor()
            model.debug([.triggers(.withDiff), .name("Counter"), .printer(output)]) { model.count }
            model.count = 5
        } result: {
            """
            Counter triggered update:
              dependency changed: DebugCounter.count:
              - 0
              + 5

            """
        }
    }

    /// `.triggers(.withDiff)` on a model-typed dependency expands the full sub-model state
    /// with `includeChildrenInMirror = true`, so callers can see exactly which nested
    /// property changed — rather than the useless `TypeName() → TypeName()` from `.withValue`.
    @Test func debugTargeted_triggers_withDiff_modelValue() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Parent") }) { output in
            let parent = DebugParent().withAnchor()
            parent.debug([.triggers(.withDiff), .name("Parent"), .printer(output)]) { parent.child }
            // Replace the whole child model so onModify(for: \DebugParent.child) fires.
            parent.child = DebugCounter(count: 5)
        } result: {
            """
            Parent triggered update:
              dependency changed: DebugParent.child:
                DebugCounter(
              -   count: 0,
              +   count: 5,
                  name: "default"
                )

            """
        }
    }

    /// `.triggers(.withValue)` reports the old → new value of each changed dependency.
    @Test func memoizeDebug_triggersWithValue() async throws {
        try await assertOutputSnapshot(until: { $0.contains("debugDoubled") }) { output in
            let debugOpts: DebugOptions = [.triggers(.withValue), .printer(output)]
            let model = DebugCounter().withAnchor()
            _ = model.node.memoize(for: "debugDoubled", debug: debugOpts, produce: { model.count * 2 })
            model.count = 5
        } result: {
            """
            DebugCounter[memoize: "debugDoubled"] triggered update:
              dependency changed: DebugCounter.count: 0 → 5

            """
        }
    }

    /// `.changes(.diff)` shows a `−`/`+` diff of the memoized value across updates.
    @Test func memoizeDebug_changesOnly_diff() async throws {
        try await assertOutputSnapshot(until: { $0.contains("debugDoubled") }) { output in
            let debugOpts: DebugOptions = [.changes(.diff), .printer(output)]
            let model = DebugCounter().withAnchor()
            _ = model.node.memoize(for: "debugDoubled", debug: debugOpts, produce: { model.count * 2 })
            model.count = 5
        } result: {
            """
            DebugCounter[memoize: "debugDoubled"] value changed:
            - 0
            + 10

            """
        }
    }

    // MARK: No output when value unchanged

    /// Setting a property to its current value must not produce any debug output.
    /// Only the subsequent real change (0 → 1) should appear.
    @Test func debugNoOutput_whenValueUnchanged() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter().withAnchor()
            model.debug([.changes(), .name("Counter"), .printer(output)])
            model.count = 0  // same value — must not produce a diff
            model.count = 1  // real change — must produce output
        } result: {
            """
            Counter value changed:
              DebugCounter(
            -   count: 0,
            +   count: 1,
                name: "default"
              )

            """
        }
    }
}
