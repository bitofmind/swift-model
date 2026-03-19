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

/// Runs `build` inside `waitUntilRemoved`, then asserts the captured output matches the inline snapshot.
///
/// Use this to reduce boilerplate in debug tests that follow the pattern:
/// create a `CaptureStream`, anchor a model, set up debug, mutate, wait, assert.
///
/// ```swift
/// @Test func myDebugTest() async throws {
///     try await assertOutputSnapshot { output in
///         let model = MyModel().withAnchor()
///         model.debug([.changes(), .printer(output)])
///         model.value = 42
///         try await waitUntil(output.captured.contains("MyModel"))
///         return model
///     } result: {
///         """
///         MyModel value changed:
///         ...
///         """
///     }
/// }
/// ```
func assertOutputSnapshot<M: Model>(
    fileID: StaticString = #fileID,
    file: StaticString = #filePath,
    function: StaticString = #function,
    line: UInt = #line,
    column: UInt = #column,
    _ build: (CaptureStream) async throws -> M,
    result expected: (() -> String)? = nil
) async throws {
    let output = CaptureStream()
    try await waitUntilRemoved {
        try await build(output)
    }
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
        try await assertOutputSnapshot { output in
            let model = DebugCounter().withAnchor()
            model.debug([.changes(), .name("Counter"), .printer(output)])
            model.count = 1
            try await waitUntil(output.captured.contains("Counter"))
            return model
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
        try await assertOutputSnapshot { output in
            let parent = DebugParent().withAnchor()
            parent.debug([.changes(), .name("Parent"), .printer(output)])
            parent.child.count = 5
            try await waitUntil(output.captured.contains("Parent"))
            return parent
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
        try await assertOutputSnapshot { output in
            let model = DebugCounter().withAnchor()
            model.debug([.changes(.value), .name("Counter"), .printer(output)])
            model.count = 42
            try await waitUntil(output.captured.contains("Counter"))
            return model
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
    // Note: debug<T>() with a closure captures the model struct, which creates a retain cycle
    // with context.cancellations. These tests hold the model locally rather than using
    // waitUntilRemoved, since the observation intentionally lives for the model's lifetime.

    @Test func debugTargeted_triggers_name() async throws {
        let output = CaptureStream()
        let model = DebugCounter().withAnchor()
        model.debug([.triggers(), .name("Counter"), .printer(output)]) { model.count }

        model.count = 5

        try await waitUntil(output.captured.contains("Counter"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            Counter triggered update:
              dependency changed: DebugCounter.count

            """
        }
    }

    @Test func debugTargeted_triggers_withValue() async throws {
        let output = CaptureStream()
        let model = DebugCounter().withAnchor()
        model.debug([.triggers(.withValue), .name("Counter"), .printer(output)]) { model.count }

        model.count = 7

        try await waitUntil(output.captured.contains("Counter"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            Counter triggered update:
              dependency changed: DebugCounter.count = 7

            """
        }
    }

    @Test func debugTargeted_triggersAndChanges() async throws {
        let output = CaptureStream()
        let model = DebugCounter().withAnchor()
        model.debug([.triggers(), .changes(), .name("Counter"), .printer(output)]) { model.count }

        model.count = 3

        try await waitUntil(output.captured.contains("Counter"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            Counter triggered update:
              dependency changed: DebugCounter.count
            Counter value changed:
            - 0
            + 3

            """
        }
    }

    // MARK: memoize(debug:)

    @Test func memoizeDebug_triggersAndChanges() async throws {
        let output = CaptureStream()
        let debugOpts: DebugOptions = [.triggers(.name), .changes(.value), .printer(output)]
        let model = DebugCounter().withAnchor()
        _ = model.node.memoize(for: "debugDoubled", debug: debugOpts, produce: { model.count * 2 })

        model.count = 5

        try await waitUntil(output.captured.contains("debugDoubled"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            DebugCounter[memoize: "debugDoubled"] triggered update:
              dependency changed: DebugCounter.count
            DebugCounter[memoize: "debugDoubled"] = 10

            """
        }
    }

    // MARK: Observed(debug:)

    @Test func observedDebug_triggers() async throws {
        let received = LockIsolated<[Int]>([])

        try await waitUntilRemoved {
            let model = DebugCounter()
                .withActivation { model in
                    model.node.forEach(Observed(debug: [.triggers(.name)]) { model.count }) { value in
                        received.withValue { $0.append(value) }
                    }
                }
                .withAnchor()

            model.count = 9

            try await waitUntil(received.value.contains(9))
            return model
        }
        #expect(received.value.contains(9))
    }

    // MARK: node.debug { } — closure returns model directly (subscribeToReturnedModels path)

    /// When the debug closure returns `model` itself no property reads are recorded by
    /// withObservationTracking / AccessCollector, so `subscribeToReturnedModels` must
    /// subscribe via `onAnyModification` and bypass `isSame` to fire the update.
    @Test func debugTargeted_changes_selfReturn() async throws {
        let output = CaptureStream()
        let model = DebugCounter().withAnchor()
        model.debug([.changes(), .name("Counter"), .printer(output)]) { model }

        model.count = 4

        try await waitUntil(output.captured.contains("Counter"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
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
        let output = CaptureStream()
        let parent = DebugParent().withAnchor()
        parent.debug([.changes(), .name("Child"), .printer(output)]) { parent.child }

        parent.child.count = 7

        try await waitUntil(output.captured.contains("Child"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
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
        try await assertOutputSnapshot { output in
            let model = DebugCounter()
                .withDebug([.changes(), .name("Counter"), .printer(output)])
                .withAnchor()
            model.count = 11
            try await waitUntil(output.captured.contains("Counter"))
            return model
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
        let output = CaptureStream()
        let parent = DebugDualParent().withAnchor()
        parent.debug([.changes(), .name("Dual"), .printer(output)]) { (parent.a, parent.b) }

        parent.a.count = 3

        try await waitUntil(output.captured.contains("Dual"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
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

        parent.child = DebugCounter()
        try await waitUntil(output.captured.contains("Opt"))
        output.reset()

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
        let output = CaptureStream()
        let parent = DebugDualParent().withAnchor()
        parent.debug([.changes(), .name("Arr"), .printer(output)]) { [parent.a, parent.b] }

        parent.b.count = 7

        try await waitUntil(output.captured.contains("Arr"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
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

        // Mutate first child
        parent.active.count = 5
        try await waitUntil(output.captured.contains("Swap"))
        output.reset()

        // Swap to second child — should get a new snapshot
        parent.useSecond = true
        try await waitUntil(output.captured.contains("Swap"))
        output.reset()

        // Mutate new active child — should fire
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

    @Test func debugShallow_doesNotTrackChildren() async throws {
        let output = CaptureStream()
        let parent = DebugParent().withAnchor()
        parent.debug([.triggers(), .changes(), .name("Parent"), .printer(output)]) { parent.tag }

        parent.child.count = 99
        parent.tag = "updated"

        try await waitUntil(output.captured.contains("Parent"))

        assertInlineSnapshot(of: output.captured, as: .lines) {
            """
            Parent triggered update:
              dependency changed: DebugParent.tag
            Parent value changed:
            - "parent"
            + "updated"

            """
        }
        #expect(!output.captured.contains("DebugCounter.count"))
    }
}
