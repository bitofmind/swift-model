import Testing
import AsyncAlgorithms
@testable import SwiftModel
import Foundation

/// Tests for ModelNode.captureState() / restoreState()
struct StateCaptureTests {

    // MARK: - Basic capture and restore

    @Test func testCaptureRestorePlainProperties() {
        let model = Counter().withAnchor()

        model.count = 5
        let snapshot = model.node.captureState()

        model.count = 99
        #expect(model.count == 99)

        model.node.restoreState(snapshot)
        #expect(model.count == 5)
    }

    @Test func testMultiplePropertiesRestored() {
        let model = FormModel().withAnchor()
        model.name = "Alice"
        model.age = 30

        let snapshot = model.node.captureState()

        model.name = "Bob"
        model.age = 99

        model.node.restoreState(snapshot)
        #expect(model.name == "Alice")
        #expect(model.age == 30)
    }

    @Test func testRestoreToInitialState() {
        let model = Counter().withAnchor()
        let initialSnapshot = model.node.captureState()

        model.count = 42
        model.node.restoreState(initialSnapshot)
        #expect(model.count == 0)
    }

    @Test func testSnapshotIsImmutable() {
        let model = Counter().withAnchor()
        model.count = 10
        let snapshot = model.node.captureState()

        // Mutate model after capture — snapshot must not change
        model.count = 999
        #expect(snapshot.frozenValue.count == 10)
    }

    // MARK: - Undo/redo stack

    @Test func testUndoRedoStack() {
        let model = Counter().withAnchor()
        var undoStack: [ModelStateSnapshot<Counter>] = []
        var redoStack: [ModelStateSnapshot<Counter>] = []

        func push() {
            undoStack.append(model.node.captureState())
            redoStack.removeAll()
        }

        func undo() {
            guard let snapshot = undoStack.popLast() else { return }
            redoStack.append(model.node.captureState())
            model.node.restoreState(snapshot)
        }

        func redo() {
            guard let snapshot = redoStack.popLast() else { return }
            undoStack.append(model.node.captureState())
            model.node.restoreState(snapshot)
        }

        push(); model.count = 1
        push(); model.count = 2
        push(); model.count = 3

        undo(); #expect(model.count == 2)
        undo(); #expect(model.count == 1)
        redo(); #expect(model.count == 2)

        // New change clears redo
        push(); model.count = 5
        #expect(redoStack.isEmpty)

        undo(); #expect(model.count == 2)
        // Redo restores 5
        redo(); #expect(model.count == 5)
    }

    // MARK: - Non-optional child model (same ID preserved)

    @Test func testRestorePreservesChildContextWhenSameID() async {
        let parent = ParentWithChild().withAnchor()

        // Wait for initial activation
        await Task.yield()
        let activationsBefore = parent.child.activations.value

        parent.child.value = 10
        let snapshot = parent.node.captureState()

        parent.child.value = 99
        parent.node.restoreState(snapshot)

        #expect(parent.child.value == 10)
        // Same child ID → context reused, no extra onActivate
        #expect(parent.child.activations.value == activationsBefore)
    }

    @Test func testRestoreWithDifferentChildIDDeactivatesOldActivatesNew() async {
        let parent = ParentWithChild().withAnchor()
        // child starts with id "default-A"
        parent.child = TrackableChild(id: "A")
        await Task.yield()

        let snapshot = parent.node.captureState() // snapshot has child "A"

        // Replace child with a different ID
        parent.child = TrackableChild(id: "B")
        await Task.yield()

        parent.node.restoreState(snapshot) // should remove "B", restore "A"
        await Task.yield()

        #expect(parent.child.id == "A")
    }

    // MARK: - Optional child model

    @Test func testRestoreNilsOptionalChild() {
        let parent = ParentWithOptionalChild().withAnchor()
        let snapshot = parent.node.captureState() // child is nil

        parent.child = TrackableChild(id: "X")
        #expect(parent.child != nil)

        parent.node.restoreState(snapshot)
        #expect(parent.child == nil)
    }

    @Test func testRestorePopulatesOptionalChild() {
        let parent = ParentWithOptionalChild().withAnchor()
        parent.child = TrackableChild(id: "X")
        parent.child?.value = 7
        let snapshot = parent.node.captureState() // child is X with value 7

        parent.child = nil
        #expect(parent.child == nil)

        parent.node.restoreState(snapshot)
        #expect(parent.child?.id == "X")
        #expect(parent.child?.value == 7)
    }

    // MARK: - Array of child models

    @Test func testRestoreChildArray() {
        let parent = ParentWithChildren().withAnchor()
        parent.children = [NumberedChild(id: 1, value: 10), NumberedChild(id: 2, value: 20)]

        let snapshot = parent.node.captureState()

        parent.children = [NumberedChild(id: 3, value: 30)]

        parent.node.restoreState(snapshot)
        #expect(parent.children.count == 2)
        #expect(parent.children[0].id == 1)
        #expect(parent.children[0].value == 10)
        #expect(parent.children[1].id == 2)
        #expect(parent.children[1].value == 20)
    }

    @Test func testRestoreEmptiesChildArray() {
        let parent = ParentWithChildren().withAnchor()
        let snapshot = parent.node.captureState() // empty array

        parent.children = [NumberedChild(id: 1, value: 1), NumberedChild(id: 2, value: 2)]
        #expect(parent.children.count == 2)

        parent.node.restoreState(snapshot)
        #expect(parent.children.isEmpty)
    }

    @Test func testRestoreChildArrayPreservesExistingContexts() async {
        let parent = ParentWithChildren().withAnchor()
        parent.children = [NumberedChild(id: 1, value: 10), NumberedChild(id: 2, value: 20)]

        await Task.yield()
        let activationsBefore = parent.children[0].activations.value + parent.children[1].activations.value

        let snapshot = parent.node.captureState()
        parent.children[0].value = 99
        parent.children[1].value = 88

        parent.node.restoreState(snapshot)

        #expect(parent.children[0].value == 10)
        #expect(parent.children[1].value == 20)
        // Same IDs → contexts reused, no new onActivate calls
        let activationsAfter = parent.children[0].activations.value + parent.children[1].activations.value
        #expect(activationsAfter == activationsBefore)
    }

    @Test func testRestoreArrayRemovesExtraChild() async {
        let parent = ParentWithChildren().withAnchor()
        parent.children = [NumberedChild(id: 1, value: 10), NumberedChild(id: 2, value: 20)]

        let snapshot = parent.node.captureState() // 2 children

        // Add a 3rd child after snapshot
        parent.children.append(NumberedChild(id: 3, value: 30))
        #expect(parent.children.count == 3)

        parent.node.restoreState(snapshot)
        #expect(parent.children.count == 2)
        #expect(parent.children[0].id == 1)
        #expect(parent.children[1].id == 2)
    }

    // MARK: - Observation fires once per restore (transaction coalescing)

    @Test func testRestoreFiresObservationOnce() async {
        let model = Counter().withAnchor()
        model.count = 5
        let snapshot = model.node.captureState()

        let fireCount = Locked(0)
        let task = Task {
            for await _ in model.observeAnyModification() {
                fireCount.value += 1
                if fireCount.value >= 2 { break }
            }
        }

        // Let the observer task start and register
        await Task.yield()

        // Make two changes: first a regular mutation, then a restore.
        // Each should fire the observer exactly once (transaction coalescing).
        model.count = 99
        await Task.yield()

        model.node.restoreState(snapshot)

        // Give observation time to fire
        for _ in 1...20 {
            if fireCount.value >= 2 { break }
            await Task.yield()
        }
        task.cancel()

        // Should have fired once for count=99 and once for the restore
        // Each is one transaction = one fire
        #expect(fireCount.value == 2)
    }

    // MARK: - onChange skips restores automatically

    @Test func testOnChangeIsNotCalledDuringRestore() {
        let model = Counter().withAnchor()
        let callCount = Locked(0)

        model.node.onChange { _ in callCount.value += 1 }

        model.count = 1
        model.count = 2
        let snapshot = model.node.captureState()
        model.count = 3

        #expect(callCount.value == 3)

        // Restore should NOT fire onChange
        model.node.restoreState(snapshot)
        #expect(callCount.value == 3)  // still 3, not 4
    }

    @Test func testOnChangeLazySnapshotCapturesCorrectValue() {
        let model = Counter().withAnchor()
        let captured = Locked<ModelStateSnapshot<Counter>?>(nil)

        model.node.onChange { proxy in
            captured.value = proxy.snapshot
        }

        model.count = 42
        #expect(captured.value?.frozenValue.count == 42)
    }

    @Test func testOnChangeEagerSnapshotCapturesCorrectValue() {
        let model = Counter().withAnchor()
        let captured = Locked<ModelStateSnapshot<Counter>?>(nil)

        model.node.onChange(capture: .eager) { proxy in
            captured.value = proxy.snapshot
        }

        model.count = 42
        #expect(captured.value?.frozenValue.count == 42)
    }

    @Test func testOnChangeUndoStackDoesNotPolluteDuringRestore() {
        let model = Counter().withAnchor()
        let undoStack = Locked<[ModelStateSnapshot<Counter>]>([])

        model.node.onChange { proxy in
            undoStack.value.append(proxy.snapshot)
        }

        model.count = 1
        model.count = 2
        model.count = 3
        #expect(undoStack.value.count == 3)

        // Pop last snapshot (count=3) and restore — should NOT push again
        let snapshot = undoStack.value.popLast()!
        model.node.restoreState(snapshot)

        #expect(undoStack.value.count == 2)  // still 2, not 3
        #expect(model.count == 3)
    }

    // MARK: - Deep hierarchy restore

    @Test func testRestoreDeepHierarchy() {
        let root = DeepRoot().withAnchor()
        root.value = 1
        root.middle.value = 2
        root.middle.leaf.value = 3

        let snapshot = root.node.captureState()

        root.value = 10
        root.middle.value = 20
        root.middle.leaf.value = 30

        root.node.restoreState(snapshot)

        #expect(root.value == 1)
        #expect(root.middle.value == 2)
        #expect(root.middle.leaf.value == 3)
    }

    // MARK: - ModelIgnored not captured

    @Test func testIgnoredPropertyNotRestored() {
        var model = ModelWithIgnored().withAnchor()
        model.tracked = 10
        model.ignored = "hello"

        let snapshot = model.node.captureState()

        model.tracked = 99
        model.ignored = "world"

        model.node.restoreState(snapshot)

        #expect(model.tracked == 10)       // restored
        #expect(model.ignored == "world")  // NOT restored (@ModelIgnored has value semantics)
    }

    // MARK: - Multiple restores in sequence

    @Test func testMultipleRestoresInSequence() {
        let model = Counter().withAnchor()

        model.count = 1; let s1 = model.node.captureState()
        model.count = 2; let s2 = model.node.captureState()
        model.count = 3; let s3 = model.node.captureState()

        model.node.restoreState(s1); #expect(model.count == 1)
        model.node.restoreState(s3); #expect(model.count == 3)
        model.node.restoreState(s2); #expect(model.count == 2)
        model.node.restoreState(s1); #expect(model.count == 1)
    }

    // MARK: - Child observation fires after restore

    @Test func testChildObserversFireAfterRestore() async {
        let parent = ParentWithChild().withAnchor()
        parent.child.value = 5
        let snapshot = parent.node.captureState()
        parent.child.value = 99

        let observedValue = Locked(-1)
        let task = Task {
            for await val in Observed { parent.child.value } {
                if val == 5 {
                    observedValue.value = val
                    break
                }
            }
        }

        await Task.yield()
        parent.node.restoreState(snapshot)

        _ = await task.value

        #expect(observedValue.value == 5)
    }

    // MARK: - Capture preserves nested child values

    @Test func testCapturePreservesNestedChildValues() {
        let parent = ParentWithChild().withAnchor()
        parent.child.value = 42

        let snapshot = parent.node.captureState()
        #expect(snapshot.frozenValue.child.value == 42)
    }
}

// MARK: - Test model types (private to this file)

@Model
private struct Counter {
    var count = 0
}

@Model
private struct FormModel {
    var name = ""
    var age = 0
}

@Model
private struct TrackableChild {
    var id: String = "default"
    var value = 0
    @ModelIgnored var activations = Locked(0)
    @ModelIgnored var deactivations = Locked(0)

    func onActivate() {
        activations.value += 1
    }

    func onDeactivate() {
        deactivations.value += 1
    }
}

@Model
private struct ParentWithChild {
    var child = TrackableChild()
}

@Model
private struct ParentWithOptionalChild {
    var child: TrackableChild? = nil
}

@Model
private struct NumberedChild {
    let id: Int
    var value: Int
    @ModelIgnored var activations = Locked(0)

    func onActivate() {
        activations.value += 1
    }
}

@Model
private struct ParentWithChildren {
    var children: [NumberedChild] = []
}

@Model
private struct DeepLeaf {
    var value = 0
}

@Model
private struct DeepMiddle {
    var value = 0
    var leaf = DeepLeaf()
}

@Model
private struct DeepRoot {
    var value = 0
    var middle = DeepMiddle()
}

@Model
private struct ModelWithIgnored {
    var tracked = 0
    @ModelIgnored var ignored = ""
}
