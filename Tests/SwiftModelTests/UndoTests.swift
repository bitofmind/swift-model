import Testing
import AsyncAlgorithms
import ConcurrencyExtras
@testable import SwiftModel
import Foundation

// MARK: - trackUndo() (all fields) tests

struct TrackUndoAllTests {

    func makeStack() -> ModelUndoStack { ModelUndoStack() }

    // MARK: - Each field change creates an undo entry

    @Test func nameChangeCreatesUndoEntry() async {
        let stack = makeStack()
        let (model, tester) = MultiFieldModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.name = "Alice"
        await tester.assert { model.name == "Alice" }
        #expect(stack.canUndo)
    }

    @Test func countChangeCreatesUndoEntry() async {
        let stack = makeStack()
        let (model, tester) = MultiFieldModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.count = 5
        await tester.assert { model.count == 5 }
        #expect(stack.canUndo)
    }

    @Test func flagChangeCreatesUndoEntry() async {
        let stack = makeStack()
        let (model, tester) = MultiFieldModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.flag = true
        await tester.assert { model.flag == true }
        #expect(stack.canUndo)
    }

    // MARK: - Undo reverts changes

    @Test func undoRevertsChange() async {
        let stack = makeStack()
        let (model, tester) = MultiFieldModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.name = "Bob"
        await tester.assert { model.name == "Bob" }

        stack.undo()
        await tester.assert { model.name == "" }
        #expect(!stack.canUndo)
        #expect(stack.canRedo)
    }

    @Test func multipleUndoSteps() async {
        let stack = makeStack()
        let (model, tester) = MultiFieldModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.name = "First"
        await tester.assert { model.name == "First" }

        model.count = 42
        await tester.assert { model.count == 42 }

        stack.undo()
        await tester.assert { model.count == 0 }
        #expect(model.name == "First")

        stack.undo()
        await tester.assert { model.name == "" }
        #expect(!stack.canUndo)
    }

    // MARK: - Redo re-applies

    @Test func redoReAppliesUndoneChange() async {
        let stack = makeStack()
        let (model, tester) = MultiFieldModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.count = 7
        await tester.assert { model.count == 7 }

        stack.undo()
        await tester.assert { model.count == 0 }

        stack.redo()
        await tester.assert { model.count == 7 }
        #expect(stack.canUndo)
        #expect(!stack.canRedo)
    }

    // MARK: - Child model changes are tracked by the child itself

    @Test func childModelChangeCreatesUndoEntryViaChild() async {
        let stack = makeStack()
        let (model, tester) = ParentTrackAll().andTester(withDependencies: { $0.undoSystem.backend = stack })

        // EquatableChild registers trackUndo() in its onActivate, so changing its value
        // pushes an entry to the shared backend.
        model.child.value = 99
        await tester.assert { model.child.value == 99 }
        #expect(stack.canUndo)
    }

    @Test func undoRevertsChildModelChangeViaChild() async {
        let stack = makeStack()
        let (model, tester) = ParentTrackAll().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.child.value = 99
        await tester.assert { model.child.value == 99 }

        stack.undo()
        await tester.assert { model.child.value == 0 && model.node.undoSystem.canRedo == true }
    }

    @Test func parentTrackAllDoesNotTrackChildInternalProperties() async {
        // ParentTrackAll.trackUndo() tracks `title` and `child` as a whole value.
        // Changing child.value is tracked by EquatableChild's own trackUndo(), not the parent.
        // If EquatableChild were NOT to call trackUndo, changes to child.value would not be tracked.
        let stack = makeStack()
        let (model, tester) = ParentTrackAll().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.title = "Hello"
        await tester.assert { model.title == "Hello" }
        #expect(stack.canUndo)
        stack.undo()
        await tester.assert { model.title == "" }
    }

    // MARK: - @_ModelIgnored fields are not tracked

    @Test func ignoredFieldChangeDoesNotCreateUndoEntry() async {
        let stack = makeStack()
        var model = ModelWithIgnoredTrackAll().withAnchor(andDependencies: { $0.undoSystem.backend = stack })

        model.ignored = "world"
        await Task.yield()
        await Task.yield()
        #expect(!stack.canUndo)
    }

    // MARK: - Empty-stack operations are no-ops

    @Test func undoOnEmptyStackIsNoop() async {
        let stack = makeStack()
        let (model, tester) = MultiFieldModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        stack.undo()  // should not crash
        await tester.assert { model.count == 0 }
        #expect(!stack.canUndo)
    }

    @Test func redoOnEmptyStackIsNoop() async {
        let stack = makeStack()
        let (model, tester) = MultiFieldModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.count = 1
        await tester.assert { model.count == 1 }

        stack.redo()  // nothing to redo yet — should be a no-op
        await tester.assert { model.count == 1 }
        #expect(!stack.canRedo)
    }

    // MARK: - Undo does not generate new undo entries

    @Test func undoDoesNotCreateNewUndoEntry() async {
        let stack = makeStack()
        let (model, tester) = MultiFieldModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.count = 3
        await tester.assert { model.count == 3 }
        // 1 entry on stack

        stack.undo()
        await tester.assert { model.count == 0 }
        // Undo should not re-push: stack now has 0 undo, 1 redo
        #expect(!stack.canUndo)
        #expect(stack.canRedo)
    }
}

// MARK: - trackUndo(_ paths:) (selective) tests

struct TrackUndoSelectiveTests {

    func makeStack() -> ModelUndoStack { ModelUndoStack() }

    // MARK: - Tracked path creates undo entry

    @Test func trackedPathCreatesUndoEntry() async {
        let stack = makeStack()
        let (model, tester) = SelectiveModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.tracked = "hello"
        await tester.assert { model.tracked == "hello" }
        #expect(stack.canUndo)
    }

    // MARK: - Excluded path does not create undo entry

    @Test func excludedPathDoesNotCreateUndoEntry() async {
        let stack = makeStack()
        let (model, tester) = SelectiveModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.excluded = "world"
        await tester.assert { model.excluded == "world" }
        #expect(!stack.canUndo)
    }

    // MARK: - Undo reverts only the tracked path

    @Test func undoRevertsTrackedPath() async {
        let stack = makeStack()
        let (model, tester) = SelectiveModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.tracked = "before"
        await tester.assert { model.tracked == "before" }

        stack.undo()
        await tester.assert { model.tracked == "" }
        #expect(!stack.canUndo)
        #expect(stack.canRedo)
    }

    @Test func undoOnlyRestoresTrackedPaths() async {
        // trackUndo(\.tracked) only restores the tracked paths during undo.
        // Non-tracked fields (excluded) keep their current live values.
        let stack = makeStack()
        let (model, tester) = SelectiveModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        // Set tracked (creates undo entry)
        model.tracked = "T"
        await tester.assert { model.tracked == "T" }

        // Change excluded — no new undo entry; it's ephemeral state
        model.excluded = "E"
        await tester.assert { model.excluded == "E" }

        // Undo reverts tracked to "", but excluded stays at its live value "E"
        stack.undo()
        await tester.assert { model.tracked == "" && model.excluded == "E" }
    }

    // MARK: - Multiple tracked paths

    @Test func multiplePaths_bothCreateEntries() async {
        let stack = makeStack()
        let (model, tester) = TwoTrackedModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.alpha = 1
        await tester.assert { model.alpha == 1 }
        #expect(stack.canUndo)

        model.beta = 2
        await tester.assert { model.beta == 2 }

        stack.undo()
        await tester.assert { model.beta == 0 }
        #expect(model.alpha == 1)

        stack.undo()
        await tester.assert { model.alpha == 0 }
        #expect(!stack.canUndo)
    }

    // MARK: - Redo for selective tracking

    @Test func redoReAppliesSelectiveChange() async {
        let stack = makeStack()
        let (model, tester) = SelectiveModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.tracked = "hello"
        await tester.assert { model.tracked == "hello" }

        stack.undo()
        await tester.assert { model.tracked == "" }
        #expect(stack.canRedo)

        stack.redo()
        await tester.assert { model.tracked == "hello" }
        #expect(stack.canUndo)
        #expect(!stack.canRedo)
    }

    // MARK: - New change after undo clears redo

    @Test func newChangeAfterUndoClearsRedo() async {
        let stack = makeStack()
        let (model, tester) = SelectiveModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.tracked = "A"
        await tester.assert { model.tracked == "A" }

        stack.undo()
        await tester.assert { model.tracked == "" && stack.canRedo == true }

        model.tracked = "B"
        await tester.assert { model.tracked == "B" }
        #expect(!stack.canRedo)
        #expect(stack.canUndo)
    }

    // MARK: - Container path tracking: child item property changes are undoable

    @Test func containerPath_itemPropertyChangeIsUndoable() async {
        let stack = makeStack()
        let (model, tester) = ContainerTrackedModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.items.append(EquatableChild(value: 0))
        await tester.assert { model.items.count == 1 && stack.canUndo == true }

        model.items[0].value = 42
        await tester.assert { model.items.first?.value == 42 && stack.canUndo == true }

        stack.undo()
        await tester.assert { model.items.first?.value == 0 }
    }

    @Test func containerPath_undoRevertsContainerButNotExcluded() async {
        let stack = makeStack()
        let (model, tester) = ContainerTrackedModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        model.items.append(EquatableChild(value: 1))
        await tester.assert { model.items.count == 1 }

        // Change the excluded field — no new undo entry
        model.extra = "ephemeral"
        await tester.assert { model.extra == "ephemeral" }

        // Undo reverts items but leaves extra at its live value
        stack.undo()
        await tester.assert { model.items.isEmpty && model.extra == "ephemeral" }
    }
}

// MARK: - Observation tests: undo/redo triggers observers

/// Verifies that undoing and redoing a change properly notifies observers on both
/// the AccessCollector path (pre-iOS 17 / .disableObservationRegistrar) and the
/// ObservationRegistrar path (iOS 17+ `withObservationTracking`).
///
/// Serialized because these tests assert against external async state (`observed.value`)
/// that is updated by a `for await` loop. The tester has no hook into that external
/// state, so it can only poll. Serialization prevents competing test tasks from
/// delaying the cooperative scheduler turns needed for the for-await body to run.
@Suite(.serialized)
struct UndoObservationTests {

    // MARK: - Direct property (trackUndo())

    @Test(arguments: UpdatePath.allCases)
    func undoNotifiesObserverOfDirectProperty(updatePath: UpdatePath) async throws {
        let stack = ModelUndoStack()
        let (model, tester) = MultiFieldModel().andTester(
            options: updatePath.options,
            withDependencies: { $0.undoSystem.backend = stack }
        )
        tester.exhaustivity = .off

        let observed = LockIsolated<[Int]>([])
        let task = Task {
            for await value in Observed({ model.count }) {
                observed.withValue { $0.append(value) }
            }
        }
        defer { task.cancel() }

        // Wait for initial observation value
        await tester.assert() { observed.value.count >= 1 }

        model.count = 42
        await tester.assert() { observed.value.last == 42 }

        stack.undo()
        await tester.assert() { observed.value.last == 0 }
    }

    @Test(arguments: UpdatePath.allCases)
    func redoNotifiesObserverOfDirectProperty(updatePath: UpdatePath) async throws {
        let stack = ModelUndoStack()
        let (model, tester) = MultiFieldModel().andTester(
            options: updatePath.options,
            withDependencies: { $0.undoSystem.backend = stack }
        )
        tester.exhaustivity = .off

        let observed = LockIsolated<[Int]>([])
        let task = Task {
            for await value in Observed({ model.count }) {
                observed.withValue { $0.append(value) }
            }
        }
        defer { task.cancel() }

        await tester.assert() { observed.value.count >= 1 }

        model.count = 7
        await tester.assert() { observed.value.last == 7 }

        stack.undo()
        await tester.assert() { observed.value.last == 0 }

        stack.redo()
        await tester.assert() { observed.value.last == 7 }
    }

    // MARK: - Container item property (trackUndo(\.items))

    @Test(arguments: UpdatePath.allCases)
    func undoNotifiesObserverOfContainerItemProperty(updatePath: UpdatePath) async throws {
        let stack = ModelUndoStack()
        // Start with an item already in the model so the undo stack is clean from the start
        let (model, tester) = ContainerTrackedModel(items: [EquatableChild(value: 0)]).andTester(
            options: updatePath.options,
            withDependencies: { $0.undoSystem.backend = stack }
        )
        tester.exhaustivity = .off

        // Observe the item's value property
        let observedValues = LockIsolated<[Int]>([])
        let task = Task {
            for await value in Observed({ model.items.first?.value ?? -1 }) {
                observedValues.withValue { $0.append(value) }
            }
        }
        defer { task.cancel() }

        await tester.assert() { observedValues.value.count >= 1 }

        model.items[0].value = 99
        await tester.assert() { observedValues.value.last == 99 }

        // Undo the item value change — observer should see the revert
        stack.undo()
        await tester.assert() { observedValues.value.last == 0 }
    }
}

// MARK: - ModelUndoSystem observable state tests

struct ModelUndoSystemTests {

    @Test func canUndoCanRedoUpdateReactively() async {
        let stack = ModelUndoStack()
        let (model, tester) = MultiFieldModel().andTester(withDependencies: { $0.undoSystem.backend = stack })

        // Initially no undo/redo available
        #expect(!model.node.undoSystem.canUndo)
        #expect(!model.node.undoSystem.canRedo)

        model.count = 1
        await tester.assert { model.count == 1 }

        // Wait for canUndo to propagate through the async availability stream
        await tester.assert { model.node.undoSystem.canUndo == true }

        stack.undo()
        await tester.assert { model.count == 0 }
        await tester.assert { model.node.undoSystem.canUndo == false }
        await tester.assert { model.node.undoSystem.canRedo == true }
    }
}

// MARK: - Test model types

@Model
private struct MultiFieldModel {
    var name = ""
    var count = 0
    var flag = false

    func onActivate() {
        node.trackUndo()
    }
}

@Model
private struct ParentTrackAll {
    var title = ""
    var child = EquatableChild()

    func onActivate() {
        node.trackUndo()
    }
}

@Model
private struct EquatableChild: Equatable {
    var value = 0

    func onActivate() {
        node.trackUndo()
    }
}

@Model
private struct ModelWithIgnoredTrackAll {
    @_ModelIgnored var ignored = ""

    func onActivate() {
        node.trackUndo()
    }
}

@Model
private struct SelectiveModel {
    var tracked = ""
    var excluded = ""

    func onActivate() {
        node.trackUndo(\.tracked)
    }
}

@Model
private struct TwoTrackedModel {
    var alpha = 0
    var beta = 0

    func onActivate() {
        node.trackUndo(\.alpha, \.beta)
    }
}

@Model
private struct ContainerTrackedModel {
    var items: [EquatableChild] = []
    var extra = ""

    func onActivate() {
        node.trackUndo(\.items)
    }
}

// MARK: - Models for double-registration tests

@Model
private struct DoubleTrackUndoAllModel {
    var value = 0

    func onActivate() {
        node.trackUndo()
    }

    func trackAgain() {
        node.trackUndo() // second call — should be ignored with an issue
    }
}

@Model
private struct DoubleTrackUndoSelectiveModel {
    var value = 0

    func onActivate() {
        node.trackUndo(\.value)
    }

    func trackAgain() {
        node.trackUndo(\.value) // second call — should be ignored with an issue
    }
}

@Model
private struct DoubleTrackUndoExcludingModel {
    var value = 0
    var other = 0

    func onActivate() {
        node.trackUndo(excluding: \.other)
    }

    func trackAgain() {
        node.trackUndo(excluding: \.other) // second call — should be ignored with an issue
    }
}

// MARK: - Double-registration guard tests

struct TrackUndoDoubleRegistrationTests {

    /// Calling trackUndo() twice reports an issue and only installs one observer,
    /// so a single mutation produces exactly one undo entry (not two).
    @Test func doubleTrackUndoAllReportsIssue() async {
        let stack = ModelUndoStack()
        let (model, tester) = DoubleTrackUndoAllModel()
            .andTester(withDependencies: { $0.undoSystem.backend = stack })
        withKnownIssue {
            model.trackAgain()
        }
        model.value = 1
        await tester.assert { model.value == 1 }
        // Undo once — the stack should then be empty, proving only one entry was pushed
        #expect(stack.canUndo)
        stack.undo()
        #expect(!stack.canUndo)
        await tester.assert { model.value == 0 }
    }

    /// Calling trackUndo(_:) twice reports an issue and only installs one observer.
    @Test func doubleTrackUndoSelectiveReportsIssue() async {
        let stack = ModelUndoStack()
        let (model, tester) = DoubleTrackUndoSelectiveModel()
            .andTester(withDependencies: { $0.undoSystem.backend = stack })
        withKnownIssue {
            model.trackAgain()
        }
        model.value = 1
        await tester.assert { model.value == 1 }
        #expect(stack.canUndo)
        stack.undo()
        #expect(!stack.canUndo)
        await tester.assert { model.value == 0 }
    }

    /// Calling trackUndo(excluding:) twice reports an issue and only installs one observer.
    @Test func doubleTrackUndoExcludingReportsIssue() async {
        let stack = ModelUndoStack()
        let (model, tester) = DoubleTrackUndoExcludingModel()
            .andTester(withDependencies: { $0.undoSystem.backend = stack })
        withKnownIssue {
            model.trackAgain()
        }
        model.value = 1
        await tester.assert { model.value == 1 }
        #expect(stack.canUndo)
        stack.undo()
        #expect(!stack.canUndo)
        await tester.assert { model.value == 0 }
    }
}
