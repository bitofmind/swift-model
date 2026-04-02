import Testing
import AsyncAlgorithms
import ConcurrencyExtras
import Observation
@testable import SwiftModel
import SwiftModel

// MARK: - trackUndo() (all fields) tests

@Suite(.modelTesting)
struct TrackUndoAllTests {

    func makeStack() -> ModelUndoStack { ModelUndoStack() }

    // MARK: - Each field change creates an undo entry

    @Test func nameChangeCreatesUndoEntry() async {
        let stack = makeStack()
        let model = MultiFieldModel().withAnchor { $0.undoSystem.backend = stack }

        model.name = "Alice"
        await expect(model.name == "Alice")
        #expect(stack.canUndo)
    }

    @Test func countChangeCreatesUndoEntry() async {
        let stack = makeStack()
        let model = MultiFieldModel().withAnchor { $0.undoSystem.backend = stack }

        model.count = 5
        await expect(model.count == 5)
        #expect(stack.canUndo)
    }

    @Test func flagChangeCreatesUndoEntry() async {
        let stack = makeStack()
        let model = MultiFieldModel().withAnchor { $0.undoSystem.backend = stack }

        model.flag = true
        await expect(model.flag == true)
        #expect(stack.canUndo)
    }

    // MARK: - Undo reverts changes

    @Test func undoRevertsChange() async {
        let stack = makeStack()
        let model = MultiFieldModel().withAnchor { $0.undoSystem.backend = stack }

        model.name = "Bob"
        await expect(model.name == "Bob")

        stack.undo()
        await expect(model.name == "")
        #expect(!stack.canUndo)
        #expect(stack.canRedo)
    }

    @Test func multipleUndoSteps() async {
        let stack = makeStack()
        let model = MultiFieldModel().withAnchor { $0.undoSystem.backend = stack }

        model.name = "First"
        await expect(model.name == "First")

        model.count = 42
        await expect(model.count == 42)

        stack.undo()
        await expect(model.count == 0)
        #expect(model.name == "First")

        stack.undo()
        await expect(model.name == "")
        #expect(!stack.canUndo)
    }

    // MARK: - Redo re-applies

    @Test func redoReAppliesUndoneChange() async {
        let stack = makeStack()
        let model = MultiFieldModel().withAnchor { $0.undoSystem.backend = stack }

        model.count = 7
        await expect(model.count == 7)

        stack.undo()
        await expect(model.count == 0)

        stack.redo()
        await expect(model.count == 7)
        #expect(stack.canUndo)
        #expect(!stack.canRedo)
    }

    // MARK: - Child model changes are tracked by the child itself

    @Test func childModelChangeCreatesUndoEntryViaChild() async {
        let stack = makeStack()
        let model = ParentTrackAll().withAnchor { $0.undoSystem.backend = stack }

        // EquatableChild registers trackUndo() in its onActivate, so changing its value
        // pushes an entry to the shared backend.
        model.child.value = 99
        await expect(model.child.value == 99)
        #expect(stack.canUndo)
    }

    @Test func undoRevertsChildModelChangeViaChild() async {
        let stack = makeStack()
        let model = ParentTrackAll().withAnchor { $0.undoSystem.backend = stack }

        model.child.value = 99
        await expect(model.child.value == 99)

        stack.undo()
        await expect(model.child.value == 0 && model.node.undoSystem.canRedo == true)
    }

    @Test func parentTrackAllDoesNotTrackChildInternalProperties() async {
        // ParentTrackAll.trackUndo() tracks `title` and `child` as a whole value.
        // Changing child.value is tracked by EquatableChild's own trackUndo(), not the parent.
        // If EquatableChild were NOT to call trackUndo, changes to child.value would not be tracked.
        let stack = makeStack()
        let model = ParentTrackAll().withAnchor { $0.undoSystem.backend = stack }

        model.title = "Hello"
        await expect(model.title == "Hello")
        #expect(stack.canUndo)
        stack.undo()
        await expect(model.title == "")
    }

    // MARK: - @_ModelIgnored fields are not tracked

    @Test func ignoredFieldChangeDoesNotCreateUndoEntry() async {
        let stack = makeStack()
        var model = ModelWithIgnoredTrackAll().withAnchor { $0.undoSystem.backend = stack }

        model.ignored = "world"
        await Task.yield()
        await Task.yield()
        #expect(!stack.canUndo)
    }

    // MARK: - Empty-stack operations are no-ops

    @Test func undoOnEmptyStackIsNoop() async {
        let stack = makeStack()
        let model = MultiFieldModel().withAnchor { $0.undoSystem.backend = stack }

        stack.undo()  // should not crash
        await expect(model.count == 0)
        #expect(!stack.canUndo)
    }

    @Test func redoOnEmptyStackIsNoop() async {
        let stack = makeStack()
        let model = MultiFieldModel().withAnchor { $0.undoSystem.backend = stack }

        model.count = 1
        await expect(model.count == 1)

        stack.redo()  // nothing to redo yet — should be a no-op
        await expect(model.count == 1)
        #expect(!stack.canRedo)
    }

    // MARK: - Undo does not generate new undo entries

    @Test func undoDoesNotCreateNewUndoEntry() async {
        let stack = makeStack()
        let model = MultiFieldModel().withAnchor { $0.undoSystem.backend = stack }

        model.count = 3
        await expect(model.count == 3)
        // 1 entry on stack

        stack.undo()
        await expect(model.count == 0)
        // Undo should not re-push: stack now has 0 undo, 1 redo
        #expect(!stack.canUndo)
        #expect(stack.canRedo)
    }
}

// MARK: - trackUndo(_ paths:) (selective) tests

@Suite(.modelTesting)
struct TrackUndoSelectiveTests {

    func makeStack() -> ModelUndoStack { ModelUndoStack() }

    // MARK: - Tracked path creates undo entry

    @Test func trackedPathCreatesUndoEntry() async {
        let stack = makeStack()
        let model = SelectiveModel().withAnchor { $0.undoSystem.backend = stack }

        model.tracked = "hello"
        await expect(model.tracked == "hello")
        #expect(stack.canUndo)
    }

    // MARK: - Excluded path does not create undo entry

    @Test func excludedPathDoesNotCreateUndoEntry() async {
        let stack = makeStack()
        let model = SelectiveModel().withAnchor { $0.undoSystem.backend = stack }

        model.excluded = "world"
        await expect(model.excluded == "world")
        #expect(!stack.canUndo)
    }

    // MARK: - Undo reverts only the tracked path

    @Test func undoRevertsTrackedPath() async {
        let stack = makeStack()
        let model = SelectiveModel().withAnchor { $0.undoSystem.backend = stack }

        model.tracked = "before"
        await expect(model.tracked == "before")

        stack.undo()
        await expect(model.tracked == "")
        #expect(!stack.canUndo)
        #expect(stack.canRedo)
    }

    @Test func undoOnlyRestoresTrackedPaths() async {
        // trackUndo(\.tracked) only restores the tracked paths during undo.
        // Non-tracked fields (excluded) keep their current live values.
        let stack = makeStack()
        let model = SelectiveModel().withAnchor { $0.undoSystem.backend = stack }

        // Set tracked (creates undo entry)
        model.tracked = "T"
        await expect(model.tracked == "T")

        // Change excluded — no new undo entry; it's ephemeral state
        model.excluded = "E"
        await expect(model.excluded == "E")

        // Undo reverts tracked to "", but excluded stays at its live value "E"
        stack.undo()
        await expect(model.tracked == "" && model.excluded == "E")
    }

    // MARK: - Multiple tracked paths

    @Test func multiplePaths_bothCreateEntries() async {
        let stack = makeStack()
        let model = TwoTrackedModel().withAnchor { $0.undoSystem.backend = stack }

        model.alpha = 1
        await expect(model.alpha == 1)
        #expect(stack.canUndo)

        model.beta = 2
        await expect(model.beta == 2)

        stack.undo()
        await expect(model.beta == 0)
        #expect(model.alpha == 1)

        stack.undo()
        await expect(model.alpha == 0)
        #expect(!stack.canUndo)
    }

    // MARK: - Redo for selective tracking

    @Test func redoReAppliesSelectiveChange() async {
        let stack = makeStack()
        let model = SelectiveModel().withAnchor { $0.undoSystem.backend = stack }

        model.tracked = "hello"
        await expect(model.tracked == "hello")

        stack.undo()
        await expect(model.tracked == "")
        #expect(stack.canRedo)

        stack.redo()
        await expect(model.tracked == "hello")
        #expect(stack.canUndo)
        #expect(!stack.canRedo)
    }

    // MARK: - New change after undo clears redo

    @Test func newChangeAfterUndoClearsRedo() async {
        let stack = makeStack()
        let model = SelectiveModel().withAnchor { $0.undoSystem.backend = stack }

        model.tracked = "A"
        await expect(model.tracked == "A")

        stack.undo()
        await expect(model.tracked == "" && stack.canRedo == true)

        model.tracked = "B"
        await expect(model.tracked == "B")
        #expect(!stack.canRedo)
        #expect(stack.canUndo)
    }

    // MARK: - Container path tracking: child item property changes are undoable

    @Test func containerPath_itemPropertyChangeIsUndoable() async {
        let stack = makeStack()
        let model = ContainerTrackedModel().withAnchor { $0.undoSystem.backend = stack }

        model.items.append(EquatableChild(value: 0))
        await expect(model.items.count == 1 && stack.canUndo == true)

        model.items[0].value = 42
        await expect(model.items.first?.value == 42 && stack.canUndo == true)

        stack.undo()
        await expect(model.items.first?.value == 0)
    }

    @Test func containerPath_undoRevertsContainerButNotExcluded() async {
        let stack = makeStack()
        let model = ContainerTrackedModel().withAnchor { $0.undoSystem.backend = stack }

        model.items.append(EquatableChild(value: 1))
        await expect(model.items.count == 1)

        // Change the excluded field — no new undo entry
        model.extra = "ephemeral"
        await expect(model.extra == "ephemeral")

        // Undo reverts items but leaves extra at its live value
        stack.undo()
        await expect(model.items.isEmpty && model.extra == "ephemeral")
    }
}

// MARK: - Observation tests: undo/redo triggers observers

/// Verifies that undoing and redoing a change properly notifies observers on both
/// the AccessCollector path (pre-iOS 17 / .disableObservationRegistrar) and the
/// ObservationRegistrar path (iOS 17+ `withObservationTracking`).
///
/// These tests verify that undo/redo triggers model observation notifications by
/// asserting on the model state directly via `expect`. This works because
/// `TestAccess.didModify` fires through the same `invokeDidModify` path as
/// `AccessCollector` and `withObservationTracking` — so confirming the model state
/// changed also confirms that async `Observed` streams would be notified.
@Suite(.modelTesting, .serialized)
struct UndoObservationTests {

    // MARK: - Direct property (trackUndo())

    @Test(arguments: UpdatePath.allCases)
    func undoNotifiesObserverOfDirectProperty(updatePath: UpdatePath) async throws {
        let stack = ModelUndoStack()
        let model = updatePath.withOptions {
            MultiFieldModel().withAnchor {
                $0.undoSystem.backend = stack
            }
        }

        model.count = 42
        await expect {
            model.count == 42
            model.node.undoSystem.canUndo == true
        }

        stack.undo()
        await expect {
            model.count == 0
            model.node.undoSystem.canUndo == false
            model.node.undoSystem.canRedo == true
        }
    }

    @Test(arguments: UpdatePath.allCases)
    func redoNotifiesObserverOfDirectProperty(updatePath: UpdatePath) async throws {
        let stack = ModelUndoStack()
        let model = updatePath.withOptions {
            MultiFieldModel().withAnchor {
                $0.undoSystem.backend = stack
            }
        }

        model.count = 7
        await expect {
            model.count == 7
            model.node.undoSystem.canUndo == true
        }

        stack.undo()
        await expect {
            model.count == 0
            model.node.undoSystem.canUndo == false
            model.node.undoSystem.canRedo == true
        }

        stack.redo()
        await expect {
            model.count == 7
            model.node.undoSystem.canUndo == true
            model.node.undoSystem.canRedo == false
        }
    }

    // MARK: - Container item property (trackUndo(\.items))

    @Test(arguments: UpdatePath.allCases)
    func undoNotifiesObserverOfContainerItemProperty(updatePath: UpdatePath) async throws {
        let stack = ModelUndoStack()
        // Start with an item already in the model so the undo stack is clean from the start
        let model = updatePath.withOptions {
            ContainerTrackedModel(items: [EquatableChild(value: 0)]).withAnchor {
                $0.undoSystem.backend = stack
            }
        }

        print("[UNDO-DIAG \(updatePath)] anchored, writing value=99")
        model.items[0].value = 99
        print("[UNDO-DIAG \(updatePath)] entering first expect")
        await expect {
            model.items[0].value == 99
            model.node.undoSystem.canUndo == true
        }
        print("[UNDO-DIAG \(updatePath)] first expect passed")

        // Undo the item value change — observer should see the revert
        print("[UNDO-DIAG \(updatePath)] calling stack.undo()")
        stack.undo()
        print("[UNDO-DIAG \(updatePath)] stack.undo() returned, canUndo=\(stack.canUndo) canRedo=\(stack.canRedo)")
        print("[UNDO-DIAG \(updatePath)] model.items[0].value=\(model.items[0].value)")
        print("[UNDO-DIAG \(updatePath)] entering second expect")
        await expect {
            model.items[0].value == 0
            model.node.undoSystem.canUndo == false
            model.node.undoSystem.canRedo == true
        }
        print("[UNDO-DIAG \(updatePath)] second expect passed")
    }
}

// MARK: - ModelUndoSystem observable state tests

@Suite(.modelTesting)
struct ModelUndoSystemTests {

    @Test func canUndoCanRedoUpdateReactively() async {
        let stack = ModelUndoStack()
        let model = MultiFieldModel().withAnchor { $0.undoSystem.backend = stack }

        // Initially no undo/redo available
        #expect(!model.node.undoSystem.canUndo)
        #expect(!model.node.undoSystem.canRedo)

        model.count = 1
        await expect(model.count == 1)

        // Wait for canUndo to propagate through the async availability stream
        await expect(model.node.undoSystem.canUndo == true)

        stack.undo()
        await expect(model.count == 0)
        await expect(model.node.undoSystem.canUndo == false)
        await expect(model.node.undoSystem.canRedo == true)
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

@Suite(.modelTesting)
struct TrackUndoDoubleRegistrationTests {

    /// Calling trackUndo() twice reports an issue and only installs one observer,
    /// so a single mutation produces exactly one undo entry (not two).
    @Test func doubleTrackUndoAllReportsIssue() async {
        let stack = ModelUndoStack()
        let model = DoubleTrackUndoAllModel().withAnchor { $0.undoSystem.backend = stack }
        withKnownIssue {
            model.trackAgain()
        }
        model.value = 1
        await expect(model.value == 1)
        // Undo once — the stack should then be empty, proving only one entry was pushed
        #expect(stack.canUndo)
        stack.undo()
        #expect(!stack.canUndo)
        await expect(model.value == 0)
    }

    /// Calling trackUndo(_:) twice reports an issue and only installs one observer.
    @Test func doubleTrackUndoSelectiveReportsIssue() async {
        let stack = ModelUndoStack()
        let model = DoubleTrackUndoSelectiveModel().withAnchor { $0.undoSystem.backend = stack }
        withKnownIssue {
            model.trackAgain()
        }
        model.value = 1
        await expect(model.value == 1)
        #expect(stack.canUndo)
        stack.undo()
        #expect(!stack.canUndo)
        await expect(model.value == 0)
    }

    /// Calling trackUndo(excluding:) twice reports an issue and only installs one observer.
    @Test func doubleTrackUndoExcludingReportsIssue() async {
        let stack = ModelUndoStack()
        let model = DoubleTrackUndoExcludingModel().withAnchor { $0.undoSystem.backend = stack }
        withKnownIssue {
            model.trackAgain()
        }
        model.value = 1
        await expect(model.value == 1)
        #expect(stack.canUndo)
        stack.undo()
        #expect(!stack.canUndo)
        await expect(model.value == 0)
    }
}
