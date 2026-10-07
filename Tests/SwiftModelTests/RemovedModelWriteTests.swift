import Testing
@testable import SwiftModel
#if canImport(SwiftUI)
import SwiftUI
#endif

// A write to a removed model has no effect: the model keeps reading its last state.
// It is reported only when it most likely is a bug — work that outlived the model and
// meant to write to its replacement. Expected writes stay silent: the model's own work
// cleaning up as the removal cancels it (`defer { isLoading = false }`, `onCancel`), a
// SwiftUI binding writing back after its view's model went away, and a write of the
// value the model already has.

@Model private struct WriteRoot {
    var child: WriteChild? = WriteChild()

    /// Live work holding on to a removed model and writing to it.
    func write(_ name: String, to child: WriteChild) {
        node.task {
            child.name = name
        }
    }
}

@Model private struct WriteChild {
    var name = "child"
}

@Model private struct CleanupRoot {
    var child: CleanupChild?
}

/// Writes itself while removal cancels its work.
@Model private struct CleanupChild {
    var name = "child"
    var isLoading = false
    let cleanedUp: TestProbe

    func onActivate() {
        node.task {
            isLoading = true
            defer {
                isLoading = false   // runs after removal cancelled the task
                cleanedUp("task")
            }
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        node.onCancel {
            name = "cancelled"
            cleanedUp("onCancel")
        }
    }
}

@Suite(.modelTesting(exhaustivity: .off))
struct RemovedModelWriteTests {
    @Test func writeFromOutsideIsReportedAndHasNoEffect() async {
        let root = WriteRoot().withAnchor()
        let child = root.child!
        root.child = nil
        // Also covers a model whose context is already gone (no tasks keep it alive).
        await child.waitUntilRemoved()
        let lastName = child.name

        withKnownIssue {
            child.name = "late"
        } matching: { issue in
            issue.description.contains("Modifying a removed `WriteChild` model")
        }
        #expect(child.name == lastName)
    }

    @Test func writeFromLiveWorkIsReported() async {
        let root = WriteRoot().withAnchor()
        let child = root.child!
        root.child = nil

        await withKnownIssue {
            root.write("late", to: child)
            await settle()
        } matching: { issue in
            issue.description.contains("Modifying a removed `WriteChild` model")
        }
        #expect(child.name != "late")
    }

    @Test func writingTheCurrentValueIsNotReported() async {
        let root = WriteRoot().withAnchor()
        let child = root.child!
        root.child = nil

        child.name = child.name
    }

    @Test func ownCleanupAsRemovalCancelsItIsSilent() async {
        let cleanedUp = TestProbe()
        let root = CleanupRoot(child: CleanupChild(cleanedUp: cleanedUp)).withAnchor()
        let child = root.child!
        await settle()

        root.child = nil
        // The task's `defer` and `onCancel` both write the removed child: no report.
        await expect {
            cleanedUp.wasCalled(with: "task")
            cleanedUp.wasCalled(with: "onCancel")
        }
    }

#if canImport(SwiftUI)
    @MainActor @Test func bindingWriteBackIsSilent() async {
        let root = WriteRoot().withAnchor()
        let child = root.child!
        let binding = ObservedModel(wrappedValue: child).projectedValue.name
        root.child = nil
        // No waiting for the child's context to go away: the binding's `@ObservedModel`
        // still references the model, the way a view about to disappear does. A removed
        // model drops writes from the moment it is removed.
        #expect(child.lifetime == .destructed)
        let lastName = child.name

        binding.wrappedValue = "from a dismissing view"
        #expect(child.name == lastName)
    }
#endif
}
