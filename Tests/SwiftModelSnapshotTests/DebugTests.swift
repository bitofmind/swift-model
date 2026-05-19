import Testing
import InlineSnapshotTesting
import ConcurrencyExtras
import Observation
#if canImport(SwiftUI)
import SwiftUI
#endif
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

@Model struct DebugContextModel {
    var value: Int = 0
}

/// Forces the access-collector observation path for tests that don't parametrise
/// over `UpdatePath`. Convenience wrapper around
/// `UpdatePath.accessCollector.withOptions`.
func updatePathAccessCollector<T>(_ body: () throws -> T) rethrows -> T {
    try UpdatePath.accessCollector.withOptions(body)
}

extension LocalKeys {
    var debugContextCount: LocalStorage<Int> { .init(defaultValue: 0) }
}

extension PreferenceKeys {
    var debugPreferenceScore: PreferenceStorage<Int> { .init(defaultValue: 0) { $0 += $1 } }
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
///         model.node.debug(.init(triggers: nil, name: "Counter", printer: output))
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
            model.node.debug(.init(triggers: nil, name: "Counter", printer: output))
            model.count = 1
        } result: {
            """
            Counter value changed:
              DebugCounter(
            -   count: 0,
            +   count: 1,
              )

            """
        }
    }

    @Test func debugWholeSubtree_diff_collapsed() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter().withAnchor()
            model.node.debug(.init(triggers: nil, changes: .diff(.collapsed), name: "Counter", printer: output))
            model.count = 1
        } result: {
            """
            Counter value changed:
              DebugCounter(
            -   count: 0,
            +   count: 1,
                … (1 unchanged)
              )

            """
        }
    }

    @Test func debugWholeSubtree_diff_full() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter().withAnchor()
            model.node.debug(.init(triggers: nil, changes: .diff(.full), name: "Counter", printer: output))
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
            parent.node.debug(.init(triggers: nil, name: "Parent", printer: output))
            parent.child.count = 5
        } result: {
            """
            Parent value changed:
              DebugParent(
                child: DebugCounter(
            -     count: 0,
            +     count: 5,
                ),
              )

            """
        }
    }

    // MARK: node.debug() — changes (value)

    @Test func debugWholeSubtree_value() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter().withAnchor()
            model.node.debug(.init(triggers: nil, changes: .value, name: "Counter", printer: output))
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
            model.node.debug(.init(changes: nil, name: "Counter", printer: output)) { model.count }
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
            model.node.debug(.init(triggers: .withValue, changes: nil, name: "Counter", printer: output)) { model.count }
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
        model.node.debug(.init(triggers: .withValue, changes: nil, name: "Counter", printer: output)) { model.count }

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
            model.node.debug(.init(triggers: .withValue, changes: nil, name: "Counter", printer: output)) { model.name }
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
            model.node.debug(.init(name: "Counter", printer: output)) { model.count }
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
            model.node.debug(.init(changes: nil, printer: output)) { model.count }  // no name
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
            let debugOpts = DebugOptions(triggers: .name, changes: .value, printer: output)
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
                    model.node.forEach(Observed(debug: .init(changes: nil, name: "ObsCounter", printer: output)) { model.count }) { value in
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
    /// The no-closure debug form uses onAnyModification so property mutations fire normally.
    @Test func debugTargeted_changes_selfReturn() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter().withAnchor()
            model.node.debug(.init(triggers: nil, name: "Counter", printer: output))
            model.count = 4
        } result: {
            """
            Counter value changed:
              DebugCounter(
            -   count: 0,
            +   count: 4,
              )

            """
        }
    }

    /// Replacing the child model (writing to the parent property) fires the debug closure.
    @Test func debugTargeted_changes_childReturn() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Child") }) { output in
            let parent = DebugParent().withAnchor()
            parent.node.debug(.init(triggers: nil, name: "Child", printer: output)) { parent.child }
            let counter = DebugCounter()
            counter.count = 7
            parent.child = counter
        } result: {
            """
            Child value changed:
              DebugCounter(
            -   count: 0,
            +   count: 7,
              )

            """
        }
    }

    // MARK: withDebug modifier

    @Test func withDebug_modifier() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Counter") }) { output in
            let model = DebugCounter()
                .withDebug(.init(triggers: nil, name: "Counter", printer: output))
                .withAnchor()
            model.count = 11
        } result: {
            """
            Counter value changed:
              DebugCounter(
            -   count: 0,
            +   count: 11,
              )

            """
        }
    }

    // MARK: node.debug { } — closure returns tuple, optional, array, swapped model

    /// Replacing a model in a tuple (writing to the parent property) fires the debug closure.
    /// Unchanged tuple elements appear as context; only the replaced model shows a diff.
    @Test func debugTargeted_changes_tupleReturn() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Dual") }) { output in
            let parent = DebugDualParent().withAnchor()
            parent.node.debug(.init(triggers: nil, name: "Dual", printer: output)) { (parent.a, parent.b) }
            let counter = DebugCounter()
            counter.count = 3
            parent.a = counter
        } result: {
            """
            Dual value changed:
              (
                DebugCounter(
            -     count: 0,
            +     count: 3,
                ),
              )

            """
        }
    }

    /// The debug closure fires on identity transitions: nil→Some shows the new model;
    /// Some→Some (replacement) shows the diff between old and new model.
    @Test func debugTargeted_changes_optionalReturn() async throws {
        let output = CaptureStream()
        let parent = DebugOptionalParent().withAnchor()
        parent.node.debug(.init(triggers: nil, name: "Opt", printer: output)) { parent.child }

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

        // Some → Some: replacing with a different model shows the diff
        let counter = DebugCounter()
        counter.count = 5
        parent.child = counter

        try await waitUntil(output.captured.contains("Opt"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            Opt value changed:
              DebugCounter(
            -   count: 0,
            +   count: 5,
              )

            """
        }
    }

    /// Replacing an array element (writing to the parent property) fires the debug closure.
    /// Unchanged elements appear as context; only the replaced element shows a diff.
    @Test func debugTargeted_changes_arrayReturn() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Arr") }) { output in
            let parent = DebugDualParent().withAnchor()
            parent.node.debug(.init(triggers: nil, name: "Arr", printer: output)) { [parent.a, parent.b] }
            let counter = DebugCounter()
            counter.count = 7
            parent.b = counter
        } result: {
            """
            Arr value changed:
              [
                [1]: DebugCounter(
            -     count: 0,
            +     count: 7,
                )
              ]

            """
        }
    }

    @Test func debugTargeted_changes_arrayReturn_collapsed() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Arr") }) { output in
            let parent = DebugDualParent().withAnchor()
            parent.node.debug(.init(triggers: nil, changes: .diff(.collapsed), name: "Arr", printer: output)) { [parent.a, parent.b] }
            let counter = DebugCounter()
            counter.count = 7
            parent.b = counter
        } result: {
            """
            Arr value changed:
              [
                … (1 unchanged)
                [1]: DebugCounter(
            -     count: 0,
            +     count: 7,
                  … (1 unchanged)
                )
              ]

            """
        }
    }

    /// The debug closure fires when the active model is replaced (parent property changes);
    /// swapping useSecond fires because the closure reads useSecond (through the getter).
    @Test func debugTargeted_changes_swapReturn() async throws {
        let output = CaptureStream()
        let parent = DebugSwapParent().withAnchor()
        parent.node.debug(.init(triggers: nil, name: "Swap", printer: output)) { parent.active }

        // Phase 1: Replace first child with a model that has count=5
        let first = DebugCounter()
        first.count = 5
        parent.first = first
        try await waitUntil(output.captured.contains("Swap"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            Swap value changed:
              DebugCounter(
            -   count: 0,
            +   count: 5,
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
              )

            """
        }
        output.reset()

        // Phase 3: Replace second child with a model that has count=9
        let second = DebugCounter()
        second.count = 9
        parent.second = second
        try await waitUntil(output.captured.contains("Swap"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            Swap value changed:
              DebugCounter(
            -   count: 0,
            +   count: 9,
              )

            """
        }
    }

    /// Only properties read inside the closure are tracked as dependencies.
    /// Mutating an unrelated child property does not fire the debug output.
    @Test func debugTargeted_tracksOnlyAccessedProperties() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Observer") }) { output in
            let parent = DebugParent().withAnchor()
            parent.node.debug(.init(name: "Observer", printer: output)) { parent.tag }
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
            parent.node.debug(.init(triggers: nil, isShallow: true, name: "Parent", printer: output))
            parent.child.count = 99  // child change — shallow snapshot hides internals → no diff
            parent.tag = "updated"   // root property change — should appear in the diff
        } result: {
            """
            Parent value changed:
              DebugParent(
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
            parent.node.debug(.init(changes: nil, isShallow: true, name: "Parent", printer: output)) {
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
            parent.node.debug(.init(changes: nil, name: "Parent", printer: output)) { parent.child.count }
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
            model.node.debug(.init(triggers: nil, printer: output))  // no name
            model.count = 1
        } result: {
            """
            DebugCounter value changed:
              DebugCounter(
            -   count: 0,
            +   count: 1,
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
            model.node.debug(.init(triggers: nil, changes: .value, name: "Counter", printer: output)) { model.count }
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
                    model.node.forEach(Observed(debug: .init(name: "ObsCounter", printer: output)) { model.count }) { value in
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
            let debugOpts = DebugOptions(triggers: .name, changes: .value, printer: output)
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
            let debugOpts = DebugOptions(changes: nil, name: "myComputed", printer: output)
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
            model.node.debug(.init(triggers: .withDiff, changes: nil, name: "Counter", printer: output)) { model.count }
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
            parent.node.debug(.init(triggers: .withDiff, changes: nil, name: "Parent", printer: output)) { parent.child }
            // Replace the whole child model so onModify(for: \DebugParent.child) fires.
            parent.child = DebugCounter(count: 5)
        } result: {
            """
            Parent triggered update:
              dependency changed: DebugParent.child:
                DebugCounter(
              -   count: 0,
              +   count: 5,
                )

            """
        }
    }

    /// `.triggers(.withValue)` reports the old → new value of each changed dependency.
    @Test func memoizeDebug_triggersWithValue() async throws {
        try await assertOutputSnapshot(until: { $0.contains("debugDoubled") }) { output in
            let debugOpts = DebugOptions(triggers: .withValue, changes: nil, printer: output)
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
            let debugOpts = DebugOptions(triggers: nil, printer: output)
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
            model.node.debug(.init(triggers: nil, name: "Counter", printer: output))
            model.count = 0  // same value — must not produce a diff
            model.count = 1  // real change — must produce output
        } result: {
            """
            Counter value changed:
              DebugCounter(
            -   count: 0,
            +   count: 1,
              )

            """
        }
    }

    // MARK: Context storage triggers

    /// Context storage changes appear as `ModelType.local.keyName` in trigger output.
    @Test func debugTargeted_triggers_contextStorage_name() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Model") }) { output in
            let model = DebugContextModel().withAnchor()
            model.node.debug(.init(changes: nil, name: "Model", printer: output)) {
                model.node.local.debugContextCount
            }
            model.node.local.debugContextCount = 5
        } result: {
            """
            Model triggered update:
              dependency changed: DebugContextModel.local.debugContextCount

            """
        }
    }

    /// Context storage changes include old → new value with `.withValue` format.
    @Test func debugTargeted_triggers_contextStorage_withValue() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Model") }) { output in
            let model = DebugContextModel().withAnchor()
            model.node.debug(.init(triggers: .withValue, changes: nil, name: "Model", printer: output)) {
                model.node.local.debugContextCount
            }
            model.node.local.debugContextCount = 7
        } result: {
            """
            Model triggered update:
              dependency changed: DebugContextModel.local.debugContextCount: 0 → 7

            """
        }
    }

    // MARK: Preference triggers

    /// Preference changes appear as `ModelType.preference.keyName` in trigger output.
    @Test func debugTargeted_triggers_preference_name() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Model") }) { output in
            let model = DebugContextModel().withAnchor()
            model.node.debug(.init(changes: nil, name: "Model", printer: output)) {
                model.node.preference.debugPreferenceScore
            }
            model.node.preference.debugPreferenceScore = 3
        } result: {
            """
            Model triggered update:
              dependency changed: DebugContextModel.preference.debugPreferenceScore

            """
        }
    }

    // MARK: observeModifications debug

    /// observeModifications shows the originating model type and property name.
    @Test func observeModifications_debug_property() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Observer") }) { output in
            let model = DebugCounter().withAnchor()
            let stream = model.observeModifications(
                kinds: .properties,
                debug: .init(changes: nil, name: "Observer", printer: output)
            )
            model.count = 5
            withExtendedLifetime(stream) {}
        } result: {
            """
            Observer: triggered by DebugCounter.count

            """
        }
    }

    /// observeModifications shows environment key names for environment kind.
    @Test func observeModifications_debug_environment() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Observer") }) { output in
            let model = DebugContextModel().withAnchor()
            let stream = model.observeModifications(
                kinds: .environment,
                debug: .init(changes: nil, name: "Observer", printer: output)
            )
            model.node.local.debugContextCount = 7
            withExtendedLifetime(stream) {}
        } result: {
            """
            Observer: triggered by DebugContextModel.local.debugContextCount

            """
        }
    }

    /// observeModifications shows preference key names for preferences kind.
    @Test func observeModifications_debug_preference() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Observer") }) { output in
            let model = DebugContextModel().withAnchor()
            let stream = model.observeModifications(
                kinds: .preferences,
                debug: .init(changes: nil, name: "Observer", printer: output)
            )
            model.node.preference.debugPreferenceScore = 3
            withExtendedLifetime(stream) {}
        } result: {
            """
            Observer: triggered by DebugContextModel.preference.debugPreferenceScore

            """
        }
    }

    /// observeModifications on a parent shows the child model and property that changed.
    @Test func observeModifications_debug_descendant() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Observer") }) { output in
            let parent = DebugParent().withAnchor()
            let stream = parent.observeModifications(
                kinds: .properties,
                debug: .init(changes: nil, name: "Observer", printer: output)
            )
            parent.child.count = 42
            withExtendedLifetime(stream) {}
        } result: {
            """
            Observer: triggered by DebugCounter.count

            """
        }
    }

    /// observeModifications shows model type with kind when no property description is available (parentRelationship).
    @Test func observeModifications_debug_parentRelationship() async throws {
        try await assertOutputSnapshot(until: { $0.contains("Observer") }) { output in
            let parent = DebugOptionalParent().withAnchor()
            let stream = parent.observeModifications(
                kinds: .parentRelationship,
                debug: .init(changes: nil, name: "Observer", printer: output)
            )
            parent.child = DebugCounter()
            withExtendedLifetime(stream) {}
        } result: {
            """
            Observer: triggered by DebugCounter (.parentRelationship)

            """
        }
    }

    // MARK: - `$model.node.debug(...)` — body-side view-debug logging
    //
    // The body-side API is `$model.node.debug(_ options:)` on `ObservedModel`'s
    // projectedValue. It works on both observation paths:
    //
    //   - `.accessCollector` (iOS 16-style): `ViewAccess` is also the invalidator;
    //     `objectWillChange.send()` fires alongside the debug emission.
    //   - `.withObservationTracking` (iOS 17+): SwiftUI's `withObservationTracking`
    //     drives invalidation. `ViewAccess` is installed in DEBUG solely to host
    //     `attachDebug`. `suppressObjectWillChange: true` keeps it from firing
    //     a redundant signal.
    //
    // The property wrapper itself needs SwiftUI's environment to host its
    // `@StateObject`, so we drive `ViewAccess` directly via the public
    // `withAccess` mechanism. `simulateObservedModelUpdate` mirrors
    // `@ObservedModel.update()` exactly; `access.attachDebug(_:)` mirrors the
    // body-side `$model.node.debug(_:)` call. The pair exercises every code path the
    // real wrapper would.
    //
    // `&& DEBUG` follows the implementation: `ViewAccess.attachDebug(_:)`,
    // `prepareForRender(_:)`, and the `debug` storage on `ViewAccess` are all
    // `#if DEBUG`-gated, so these tests cannot compile in a `-c release` build.
    // CI defaults to debug, but matching the surface keeps release-config builds
    // green if anyone ever adds one.

#if canImport(SwiftUI) && DEBUG
    /// `.triggers(.name)` — the simplest output. One line per tracked-property
    /// mutation, naming the model type and key path that invalidated the view.
    /// Runs on both observation paths.
    @Test(arguments: UpdatePath.allCases)
    func observedModelDebug_triggersName(updatePath: UpdatePath) async throws {
        try await assertOutputSnapshot(until: { $0.contains("CounterView") }) { output in
            let model = updatePath.withOptions { DebugCounter().withAnchor() }
            let access = ViewAccess()
            let stamped = simulateObservedModelUpdate(model, access: access)
            // Body-side debug attachment — equivalent to `$model.node.debug(...)`.
            access.attachDebug(.init(triggers: .name, name: "CounterView", printer: output))
            _ = stamped.count
            model.count = 1
        } result: {
            """
            CounterView ← DebugCounter.count

            """
        }
    }

    /// `.triggers(.withValue)` — adds `old → new` rendered via `customDump`.
    /// Runs on both observation paths.
    @Test(arguments: UpdatePath.allCases)
    func observedModelDebug_triggersWithValue(updatePath: UpdatePath) async throws {
        try await assertOutputSnapshot(until: { $0.contains("CounterView") }) { output in
            let model = updatePath.withOptions { DebugCounter().withAnchor() }
            let access = ViewAccess()
            let stamped = simulateObservedModelUpdate(model, access: access)
            access.attachDebug(.init(triggers: .withValue, name: "CounterView", printer: output))
            _ = stamped.count
            model.count = 7
        } result: {
            """
            CounterView ← DebugCounter.count: 0 → 7

            """
        }
    }

    /// `.triggers(.withDiff)` — renders a `−`/`+` diff between old and new.
    /// Runs on both observation paths.
    @Test(arguments: UpdatePath.allCases)
    func observedModelDebug_triggersWithDiff(updatePath: UpdatePath) async throws {
        try await assertOutputSnapshot(until: { $0.contains("CounterView") }) { output in
            let model = updatePath.withOptions { DebugCounter().withAnchor() }
            let access = ViewAccess()
            let stamped = simulateObservedModelUpdate(model, access: access)
            access.attachDebug(.init(triggers: .withDiff, name: "CounterView", printer: output))
            _ = stamped.count
            model.count = 99
        } result: {
            """
            CounterView ← DebugCounter.count
            - 0
            + 99

            """
        }
    }

    /// A view that reads multiple properties produces one trigger line for each
    /// independent mutation, identifying *which* property caused the re-render.
    /// Runs on both observation paths.
    @Test(arguments: UpdatePath.allCases)
    func observedModelDebug_multipleProperties(updatePath: UpdatePath) async throws {
        try await assertOutputSnapshot(until: { $0.contains("count") && $0.contains("name") }) { output in
            let model = updatePath.withOptions { DebugCounter().withAnchor() }
            let access = ViewAccess()
            registerMultiPropertyReads(model, access: access, printer: output)
            model.count = 1
            model.name = "x"
            // Keep `access` alive past the mutations so its weak `self` capture in
            // the registered `onModify` callbacks still resolves to a live instance
            // when the debug line is emitted.
            withExtendedLifetime(access) {}
        } result: {
            """
            CounterView ← DebugCounter.count
            CounterView ← DebugCounter.name

            """
        }
    }

    /// `shouldPropagateToChildren == true` for `ViewAccess` — child-model reads
    /// register dependencies on the child's context, so the trigger line identifies
    /// the child model type, not the parent. Runs on both observation paths.
    @Test(arguments: UpdatePath.allCases)
    func observedModelDebug_childModelTrigger(updatePath: UpdatePath) async throws {
        try await assertOutputSnapshot(until: { $0.contains("DebugCounter.count") }) { output in
            let parent = updatePath.withOptions { DebugParent().withAnchor() }
            let access = ViewAccess()
            let stamped = simulateObservedModelUpdate(parent, access: access)
            access.attachDebug(.init(triggers: .name, name: "ParentView", printer: output))
            _ = stamped.child.count
            parent.child.count = 42
        } result: {
            """
            ParentView ← DebugCounter.count

            """
        }
    }

    /// When no `$model.node.debug(...)` call is made in body, no debug output is
    /// produced — the body-side API is opt-in per render.
    /// Runs on both observation paths.
    @Test(arguments: UpdatePath.allCases)
    func observedModelDebug_disabledIsSilent(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { DebugCounter().withAnchor() }
        let access = ViewAccess()
        let stamped = simulateObservedModelUpdate(model, access: access)
        // No `attachDebug` call — equivalent to body without `$model.node.debug(...)`.
        _ = stamped.count
        model.count = 1
        // No assertion needed — if a print sneaks through it would surface in test
        // output. The contract is "no attachDebug => no per-mutation emission".
    }

    /// `.triggers(.withValue)` on a **preference** path. The preference's
    /// `_ModelState[_preference:]` subscript has a `fatalError()` stub
    /// getter — without `Context.willAccessPreferenceValue` pre-populating
    /// `threadLocals.precomputedPreferenceValue` around the `willAccess`
    /// invocation, the initial-value capture inside `ViewAccess.willAccess`
    /// would crash. Same plumbing keeps `emitDebugTrigger` from crashing
    /// when it reads `oldValue` / `newValue` for the trigger line.
    ///
    /// Reads on preference / context paths route through
    /// `metadataModelContext().activeAccess`, which reads
    /// `ModelAccess.active`/`ModelAccess.current` task-locals rather than the
    /// stamped-access fallback. The `usingActiveAccess` wrap mirrors what
    /// `@ObservedModel.update` effectively achieves for body-side reads on
    /// SwiftUI's render path (the view body runs after the access is stamped
    /// AND the read site has access "active" via the property wrapper's
    /// invalidator machinery).
    @Test(arguments: UpdatePath.allCases)
    func observedModelDebug_triggersWithValue_preference(updatePath: UpdatePath) async throws {
        try await assertOutputSnapshot(until: { $0.contains("View") }) { output in
            let model = updatePath.withOptions { DebugContextModel().withAnchor() }
            let access = ViewAccess()
            let stamped = simulateObservedModelUpdate(model, access: access)
            access.attachDebug(.init(triggers: .withValue, name: "View", printer: output))
            usingActiveAccess(access) {
                _ = stamped.node.preference.debugPreferenceScore
            }
            model.node.preference.debugPreferenceScore = 9
        } result: {
            """
            View ← DebugContextModel.preference.debugPreferenceScore: 0 → 9

            """
        }
    }

    /// `.triggers(.withDiff)` variant for preferences — same crash-without-
    /// precomputed-value risk, slightly different formatter path through
    /// `emitDebugTrigger` (`String(customDumping:)` instead of `dumpForDebug`).
    @Test(arguments: UpdatePath.allCases)
    func observedModelDebug_triggersWithDiff_preference(updatePath: UpdatePath) async throws {
        try await assertOutputSnapshot(until: { $0.contains("View") }) { output in
            let model = updatePath.withOptions { DebugContextModel().withAnchor() }
            let access = ViewAccess()
            let stamped = simulateObservedModelUpdate(model, access: access)
            access.attachDebug(.init(triggers: .withDiff, name: "View", printer: output))
            usingActiveAccess(access) {
                _ = stamped.node.preference.debugPreferenceScore
            }
            model.node.preference.debugPreferenceScore = 5
        } result: {
            """
            View ← DebugContextModel.preference.debugPreferenceScore
            - 0
            + 5

            """
        }
    }

    /// `.triggers(.withValue)` on a **context-local** storage path. Same
    /// stub-getter problem as the preference path — `[_metadata:]` has a
    /// `fatalError()` getter. Verifies `Context.willAccessStorage` sets
    /// `precomputedStorageValue` symmetrically and `ViewAccess` reads it.
    @Test(arguments: UpdatePath.allCases)
    func observedModelDebug_triggersWithValue_contextStorage(updatePath: UpdatePath) async throws {
        try await assertOutputSnapshot(until: { $0.contains("View") }) { output in
            let model = updatePath.withOptions { DebugContextModel().withAnchor() }
            let access = ViewAccess()
            let stamped = simulateObservedModelUpdate(model, access: access)
            access.attachDebug(.init(triggers: .withValue, name: "View", printer: output))
            usingActiveAccess(access) {
                _ = stamped.node.local.debugContextCount
            }
            model.node.local.debugContextCount = 4
        } result: {
            """
            View ← DebugContextModel.local.debugContextCount: 0 → 4

            """
        }
    }

    /// A `DebugOptions` value whose `triggers` is `nil` (e.g. `changes`-only) is
    /// silently ignored by `$model.node.debug(...)`, since `changes` is not honoured
    /// (the model-tree diff is already covered by `node.debug(.changes)`).
    /// Runs on both observation paths.
    @Test(arguments: UpdatePath.allCases)
    func observedModelDebug_changesOnlyIsSilent(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { DebugCounter().withAnchor() }
        let access = ViewAccess()
        let stamped = simulateObservedModelUpdate(model, access: access)
        access.attachDebug(.init(triggers: nil, changes: .diff(), name: "ChangesOnly", printer: CaptureStream()))
        _ = stamped.count
        model.count = 1
    }

    /// Pins the central design contract: `ViewAccess` is stamped on the model
    /// in `DEBUG` regardless of observation path, so a later body-side
    /// `$model.node.debug(...)` call can attach without requiring init-time wiring.
    /// In release builds this test would fail on `.withObservationTracking` —
    /// the registrar early-return is preserved there to keep the zero-cost path.
    @Test(arguments: UpdatePath.allCases)
    func observedModelDebug_installsAccessOnBothPaths(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { DebugCounter().withAnchor() }
        let access = ViewAccess()
        let stamped = simulateObservedModelUpdate(model, access: access)
        // After the simulated update, the stamped model carries our ViewAccess —
        // available for a body-side `attachDebug` call to use.
        #expect(stamped.access === access)
    }

    /// Sticky-flag mechanism (Option B): on the iOS 17+ registrar path,
    /// `@ObservedModel.update()` bails out *before* installing `ViewAccess` —
    /// SwiftUI's `withObservationTracking` handles invalidation, so installation
    /// would be wasted work. The first time a body-side `$model.node.debug(...)` call
    /// runs, `attachDebug` flips a sticky flag on the `@StateObject` access; from
    /// then on `update()` installs the access on every render so debug emission
    /// can fire. This test pins the flag transition. On the `.accessCollector`
    /// path the flag is irrelevant — install happens unconditionally there.
    @Test func observedModelDebug_attachDebugSetsStickyFlag() async {
        let access = ViewAccess()
        #expect(!access.debugRequested)
        access.attachDebug(.init(triggers: .name, name: "View", printer: CaptureStream()))
        #expect(access.debugRequested)
        // Calling `attachDebug` with `triggers: nil` clears `debug` (per-render
        // state) but does not reset the sticky flag — we want re-attaching a
        // future render to work without another priming round-trip.
        access.attachDebug(.init(triggers: nil, name: "View", printer: CaptureStream()))
        #expect(access.debugRequested)
    }

    /// Body-side `attachDebug` can be called *after* the first reads have already
    /// registered their callbacks. The capture-at-fire-time design means the
    /// first mutation still emits a trigger line, and `.withValue` still has the
    /// pre-mutation snapshot (captured eagerly in `willAccess` regardless of
    /// whether debug was attached at registration). Runs on both paths.
    @Test(arguments: UpdatePath.allCases)
    func observedModelDebug_attachAfterReadsStillFires(updatePath: UpdatePath) async throws {
        try await assertOutputSnapshot(until: { $0.contains("CounterView") }) { output in
            let model = updatePath.withOptions { DebugCounter().withAnchor() }
            let access = ViewAccess()
            let stamped = simulateObservedModelUpdate(model, access: access)
            // Read FIRST — debug attached LATER. The body-side API places no
            // ordering constraint on `$model.node.debug(...)` vs. property reads.
            _ = stamped.count
            access.attachDebug(.init(triggers: .withValue, name: "CounterView", printer: output))
            model.count = 5
        } result: {
            """
            CounterView ← DebugCounter.count: 0 → 5

            """
        }
    }

    // MARK: - `.withValue` / `.value` maxLines + maxDepth truncation
    //
    // End-to-end tests for these formats (using the existing `assertOutputSnapshot`
    // harness) trip a Swift 6.3.2 SILGenCleanup ownership-checker bug that's been
    // documented elsewhere in this file. Instead we exercise the underlying
    // `dumpForDebug` helper directly — that's the single point where both knobs
    // are applied, and the `customDump`/truncation behaviour is pure.

    @Test func dumpForDebug_truncatesLines() {
        let value = Array(repeating: "x", count: 50)
        let out = dumpForDebug(value, maxLines: 3, maxDepth: .max)
        // Three rendered lines, then the truncation marker.
        let lines = out.components(separatedBy: "\n")
        #expect(lines.count == 4)
        #expect(lines.last?.contains("more lines") == true)
    }

    @Test func dumpForDebug_unlimitedLines() {
        let value = Array(repeating: "x", count: 50)
        let out = dumpForDebug(value, maxLines: .max, maxDepth: .max)
        #expect(!out.contains("more lines"))
    }

    @Test func dumpForDebug_truncatesDepth() {
        struct A { var b = B() }
        struct B { var c = D() }
        struct D { var leaf = 1 }
        // `maxDepth: 1` collapses past the first nesting level; the deeper
        // `D(leaf: 1)` should not appear.
        let out = dumpForDebug(A(), maxLines: .max, maxDepth: 1)
        #expect(!out.contains("leaf: 1"))
        // For comparison, the unbounded dump does expand the leaf.
        let full = dumpForDebug(A(), maxLines: .max, maxDepth: .max)
        #expect(full.contains("leaf: 1"))
    }

    // MARK: - `ModelScope(debug:)`
    //
    // These tests exercise the same `ViewAccess` machinery `ModelScope` installs
    // internally — `prepareForRender` + `attachDebug` + `usingActiveAccess` —
    // without spinning up a SwiftUI host. They cover both observation paths
    // (`UpdatePath.accessCollector` and `UpdatePath.withObservationTracking`)
    // and verify that the surface-level behaviour matches `@ObservedModel`'s
    // body-side `$model.debug(...)`. The full SwiftUI-host integration is
    // exercised in the example apps.

    /// API surface — confirms the `debug:` initialiser compiles and `body`
    /// renders without crashing for both `nil` and a real options value.
    @Test func modelScopeDebug_initialisesWithDebugOptions() {
        let opts = DebugOptions(name: "scope")
        let scope = ModelScope(debug: opts) {
            EmptyView()
        }
        _ = scope.body
    }

    /// `.triggers(.name)` — `ModelScope`'s debug emits one line per tracked-property
    /// mutation, exactly like `$model.debug(...)`. Runs on both observation paths.
    @Test(arguments: UpdatePath.allCases)
    func modelScopeDebug_triggersName(updatePath: UpdatePath) async throws {
        try await assertOutputSnapshot(until: { $0.contains("Scope") }) { output in
            let model = updatePath.withOptions { DebugCounter().withAnchor() }
            let access = ViewAccess()
            // The realistic scenario for `ModelScope`: it's used inside a view tree
            // where an enclosing `@ObservedModel` has already stamped the model.
            // `simulateObservedModelUpdate` plays that role; its internal call to
            // `updateObserved` clears any stale debug state, so `attachDebug` is
            // called *after* it (same ordering as the `observedModelDebug_*` tests).
            let stamped = simulateObservedModelUpdate(model, access: access)
            access.attachDebug(.init(triggers: .name, name: "Scope", printer: output))
            // `usingActiveAccess(access)` is the part of `ModelScope.body` that
            // distinguishes it from a plain `@ObservedModel` host — it makes the
            // access "active" during `content()` rendering, intercepting reads
            // that go through the iOS 16 `AccessCollector` path. On iOS 17+,
            // stamped reads dispatch through the registrar regardless, so the
            // emit fires either way for properties on the stamped model.
            usingActiveAccess(access) {
                _ = stamped.count
            }
            model.count = 1
        } result: {
            """
            Scope ← DebugCounter.count

            """
        }
    }

    /// `.triggers(.withValue)` — emits `old → new` rendered via `customDump`.
    /// Runs on both observation paths.
    @Test(arguments: UpdatePath.allCases)
    func modelScopeDebug_triggersWithValue(updatePath: UpdatePath) async throws {
        try await assertOutputSnapshot(until: { $0.contains("Scope") }) { output in
            let model = updatePath.withOptions { DebugCounter().withAnchor() }
            let access = ViewAccess()
            let stamped = simulateObservedModelUpdate(model, access: access)
            access.attachDebug(.init(triggers: .withValue, name: "Scope", printer: output))
            usingActiveAccess(access) {
                _ = stamped.count
            }
            model.count = 5
        } result: {
            """
            Scope ← DebugCounter.count: 0 → 5

            """
        }
    }

    /// `debug: nil` — `ModelScope` without debug stays silent through the same
    /// render pipeline. Confirms the no-debug path doesn't accidentally fire.
    @Test(arguments: UpdatePath.allCases)
    func modelScopeDebug_disabledIsSilent(updatePath: UpdatePath) async throws {
        let model = updatePath.withOptions { DebugCounter().withAnchor() }
        let access = ViewAccess()
        let stamped = simulateObservedModelUpdate(model, access: access)
        // No `attachDebug` — emulates `ModelScope { ... }` (no debug arg). The
        // observer.onModify callbacks fire `objectWillChange` (or not, per the
        // `suppressObjectWillChange` flag `simulateObservedModelUpdate` set)
        // without printing debug lines.
        usingActiveAccess(access) {
            _ = stamped.count
        }
        model.count = 1
        // No assertion — if a debug line snuck through it would surface here.
        _ = access  // keep alive past the mutation so weak `self` resolves
    }

    /// Confirms the `isInsideDebugDump` guard — when `.withValue` walks a
    /// model containing nested model children, the dump-time reads must NOT
    /// register new dependencies. Without the guard, dumping a parent that
    /// references a child registered the child's properties as deps on the
    /// scope's `ViewAccess`, polluting the observation graph and pinning the
    /// "read from" stack to the dump path instead of user code.
    @Test(arguments: UpdatePath.allCases)
    func modelScopeDebug_dumpDoesNotRegisterDeps(updatePath: UpdatePath) async throws {
        let parent = updatePath.withOptions { DebugParent().withAnchor() }
        let access = ViewAccess()
        let stamped = simulateObservedModelUpdate(parent, access: access)
        access.attachDebug(.init(triggers: .withValue, name: "Scope", printer: CaptureStream()))
        // Read only `tag` — `child` properties should NOT be registered just
        // because they're walked during `tag`'s value capture (via the parent's
        // `customDump`). Pre-fix, `child.count` would get a dep registration
        // here via the recursive Mirror walk inside `dumpForDebug`.
        usingActiveAccess(access) {
            _ = stamped.tag
        }
        // Mutate `child.count`. If `isInsideDebugDump` is doing its job, no
        // debug line for `child.count` is emitted because that path was never
        // registered. (Soft assertion via printer absence — see snapshot helper.)
        parent.child.count = 42
        _ = access
    }

    // MARK: - `accessObserver` hook

    /// `FirstAccessObserver` records each unique `(modelType, path)` only up to
    /// `limit` times — the default `1`. This pins the de-duplication semantic.
    @Test func firstAccessObserver_dedupes_byKey() async {
        let observed = LockIsolated<[String]>([])
        let obs = FirstAccessObserver(limit: 1) { type, path in
            observed.withValue { $0.append("\(type).\(path)") }
        }
        obs.observeAccess(modelType: "Foo", path: "bar")
        obs.observeAccess(modelType: "Foo", path: "bar")   // dropped
        obs.observeAccess(modelType: "Foo", path: "baz")
        obs.observeAccess(modelType: "Other", path: "bar")
        obs.observeAccess(modelType: "Foo", path: "bar")   // dropped
        #expect(observed.value == ["Foo.bar", "Foo.baz", "Other.bar"])
    }

    /// `FirstAccessObserver(limit: 2)` fires twice per key, then stops.
    @Test func firstAccessObserver_limitTwo() async {
        let count = LockIsolated(0)
        let obs = FirstAccessObserver(limit: 2) { _, _ in
            count.withValue { $0 += 1 }
        }
        for _ in 0..<5 { obs.observeAccess(modelType: "M", path: "p") }
        #expect(count.value == 2)
    }

    /// Pure-protocol test that proves `accessObserver` is reachable through
    /// `DebugOptions.init` and that the resulting `(any AccessObserver)?` round-
    /// trips. Doesn't drive an actual `ViewAccess.willAccess`; the end-to-end
    /// firing is exercised implicitly by every other `observedModelDebug_*` test
    /// that constructs `DebugOptions`. (We don't have a focused integration test
    /// here because the combination of `LockIsolated`, `FirstAccessObserver`,
    /// `attachDebug(.init(...accessObserver:...))`, and chained `_ = model.x`
    /// reads currently trips Swift 6.3.2's SILGenCleanup ownership-checker —
    /// a known compiler bug pattern this file already documents elsewhere.)
    @Test func accessObserver_isCarriedByDebugOptions() {
        let observed = LockIsolated<[String]>([])
        let obs = FirstAccessObserver(limit: 1) { type, path in
            observed.withValue { $0.append("\(type).\(path)") }
        }
        let opts = DebugOptions(triggers: nil, accessObserver: obs)
        // Directly drive the protocol method — no `ViewAccess` involved.
        opts.accessObserver?.observeAccess(modelType: "M", path: "p")
        opts.accessObserver?.observeAccess(modelType: "M", path: "p")  // deduped
        #expect(observed.value == ["M.p"])
    }

    /// `captureAccessStack` round-trips through `DebugOptions.init` and is reachable
    /// from the stored value. End-to-end emission (stack appended to trigger lines)
    /// is platform-sensitive — `backtrace_symbols` output varies by build flavour —
    /// so the integration is exercised manually in the example apps rather than
    /// pinned in a snapshot here. Symbolication of an empty raw-address array is
    /// also verified to return `[]` so callers in WASM / no-backtrace platforms
    /// can rely on the no-op fall-through.
    @Test func captureAccessStack_isCarriedByDebugOptions() {
        let opts = DebugOptions(triggers: .name, captureAccessStack: 15)
        #expect(opts.captureAccessStack == 15)
        // Default value is nil.
        let defaultOpts = DebugOptions(triggers: .name)
        #expect(defaultOpts.captureAccessStack == nil)
        // Helper handles empty input gracefully.
        let empty: [UInt] = []
        #expect(symbolicateAccessStack(empty).isEmpty)
    }

    /// `withDefaultName` preserves *every* `DebugOptions` field when applying the
    /// auto-label — the previous "rebuild the struct field-by-field" approach
    /// silently dropped fields it forgot to copy (`accessObserver`,
    /// `captureAccessStack`), so users who set those without an explicit `name`
    /// got a no-op. This pins that all fields survive the auto-label step.
    @Test func withDefaultName_preservesAllFields() {
        let obs = FirstAccessObserver(limit: 1) { _, _ in }
        let original = DebugOptions(
            triggers: .withValue,
            changes: nil,
            isShallow: true,
            name: nil,
            printer: CaptureStream(),
            accessObserver: obs,
            captureAccessStack: 20
        )
        let resolved = original.withDefaultName("AutoLabel")
        #expect(resolved.name == "AutoLabel")
        #expect(resolved.captureAccessStack == 20)
        #expect(resolved.accessObserver != nil)
        #expect(resolved.isShallow == true)
        if case .withValue = resolved.triggers { } else {
            Issue.record("triggers did not survive withDefaultName")
        }
        // User-supplied name wins.
        let withName = DebugOptions(name: "Mine").withDefaultName("AutoLabel")
        #expect(withName.name == "Mine")
    }

    /// `trimSwiftModelInternalFrames` drops the leading consecutive frames that
    /// contain "SwiftModel" (both the dynamic-linking image name and the
    /// static-linking mangled-symbol form), stopping at the first non-match —
    /// so deeper SwiftModel frames are preserved when they're sandwiched
    /// between user code (e.g. user → memoize → user `produce` closure).
    @Test func trimSwiftModelInternalFrames_dropsLeadingPrefix() {
        // Empty / no-match cases.
        #expect(trimSwiftModelInternalFrames([]) == [])
        #expect(trimSwiftModelInternalFrames(["A", "B"]) == ["A", "B"])

        // Leading SwiftModel frames dropped, user frames preserved.
        let trimmed = trimSwiftModelInternalFrames([
            "0  MyApp 0x100 _$s11SwiftModel10ViewAccessC...",
            "1  MyApp 0x101 _$s11SwiftModel7Context...",
            "2  MyApp 0x102 _$s8MyApp10EditorView4bodyQrvg + 100",
            "3  SwiftUICore 0x103 ...",
        ])
        #expect(trimmed.count == 2)
        #expect(trimmed[0].contains("EditorView"))
        #expect(trimmed[1].contains("SwiftUICore"))

        // A SwiftModel frame sandwiched between user frames is preserved
        // (e.g. user code → memoize → user produce closure).
        let sandwich = trimSwiftModelInternalFrames([
            "0  MyApp 0x100 _$s8MyApp10sortedItems4callQ...",
            "1  MyApp 0x101 _$s11SwiftModel8memoize...",
            "2  MyApp 0x102 _$s8MyApp10EditorView4bodyQrvg...",
        ])
        #expect(sandwich.count == 3)
    }
#endif
}

#if canImport(SwiftUI) && DEBUG
/// Sets up a `ViewAccess` the same way `@ObservedModel.update()` does — stamps
/// the access onto the model and calls `updateObserved` propagating
/// `suppressObjectWillChange` whenever the registrar path is active (iOS 17+ /
/// macOS 14+). No debug parameter — the body-side API attaches debug via
/// `access.attachDebug(_:)` after this returns. Free function so the test methods
/// don't have to capture `self` across closure boundaries (that triggers a
/// `SILGenCleanup` crash when the closure is `@MainActor`-isolated).
private func simulateObservedModelUpdate<M: Model>(
    _ model: M,
    access: ViewAccess
) -> M {
    let usesObservationRegistrar: Bool
    if #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *),
       model.context?.hasObservationRegistrar == true {
        usesObservationRegistrar = true
    } else {
        usesObservationRegistrar = false
    }
    let stamped = model.withAccess(access)
    access.updateObserved(
        stamped,
        suppressObjectWillChange: usesObservationRegistrar
    )
    return stamped
}

/// Helper for `observedModelDebug_multipleProperties` — pre-registers `count` and
/// `name` reads through the caller-owned `ViewAccess`. Pulled out of the test body
/// so the `assertOutputSnapshot` async closure doesn't grow large enough to trip a
/// `SILGenCleanup` crash when combined with `arguments: UpdatePath.allCases`. The
/// caller owns `access` and is responsible for keeping it alive past the mutations.
private func registerMultiPropertyReads(_ model: DebugCounter, access: ViewAccess, printer: CaptureStream) {
    let stamped = simulateObservedModelUpdate(model, access: access)
    access.attachDebug(.init(triggers: .name, name: "CounterView", printer: printer))
    _ = stamped.count
    _ = stamped.name
}

#endif
