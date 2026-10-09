import Testing
import Foundation
import ConcurrencyExtras
@testable import SwiftModel
#if canImport(SwiftUI)
import SwiftUI
#endif

// A write to a removed model has no effect: the model keeps reading its last state.
// It is reported only when it most likely is a bug — work that outlived the model and
// meant to write to its replacement. Expected writes stay silent: the model's own work
// cleaning up as the removal cancels it (`defer { isLoading = false }`, `onCancel`,
// `onTeardown` and other signal handler runs), a
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

private enum Flush: Hashable, Sendable { case now }

@Model private struct TeardownRoot {
    var writer: TeardownWriter?
    var peer: WriteChild?
    var child: WriteChild? = WriteChild()
    let stale = LockIsolated<WriteChild?>(nil)

    /// A live model's handler writing a removed child it held on to: work that outlived
    /// the child.
    func onActivate() {
        let stale = self.stale
        node.onSignal(Flush.now) { cause in
            guard cause == .requested else { return }
            stale.value?.name = "flushed"
        }
    }
}

/// Teardown work writing removed models: itself, and a peer captured at activation (the
/// shape `onTeardown`'s docs recommend), removed before it.
@Model private struct TeardownWriter {
    var name = "writer"
    let peer: LockIsolated<WriteChild?>
    let wrote: TestProbe

    func onActivate() {
        let peer = self.peer
        node.onTeardown {
            name = "torn down"
            wrote("onTeardown")
        }
        node.onSignal(Flush.now) { cause in
            guard cause == .removed else { return }
            peer.value?.name = "flushed on removal"
            wrote("removed run")
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

    @Test func teardownHandlersWritingRemovedModelsAreSilent() async {
        let wrote = TestProbe()
        let peerBox = LockIsolated<WriteChild?>(nil)
        let root = TeardownRoot(writer: TeardownWriter(peer: peerBox, wrote: wrote), peer: WriteChild()).withAnchor()
        let writer = root.writer!
        let peer = root.peer!
        peerBox.setValue(peer)
        await settle()

        // The peer goes first, as when a test releases it before the writer's teardown.
        root.peer = nil
        root.writer = nil
        await expect {
            wrote.wasCalled(with: "onTeardown")
            wrote.wasCalled(with: "removed run")
        }
        #expect(writer.name == "writer")
        #expect(peer.name == "child")
    }

    @Test func liveModelsSignalRunWritingARemovedModelIsReported() async {
        let root = TeardownRoot().withAnchor()
        let child = root.child!
        root.stale.setValue(child)
        root.child = nil

        await withKnownIssue {
            await root.node.signal(Flush.now)
        } matching: { issue in
            issue.description.contains("Modifying a removed `WriteChild` model")
        }
        #expect(child.name == "child")
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

private struct LoadFailed: Error {}

/// Holds a `node.task`'s `catch:` handler until the test has removed the model, the way
/// a load error races the model's removal.
private final class CatchGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)

    /// Blocking waits, for a detached task to run off the test's own.
    func waitUntilEntered() { entered.wait() }
    func waitUntilFinished() { finished.wait() }
}

@Model private struct CatchRoot {
    var child: CatchChild?
}

@Model private struct CatchChild {
    var loadError: String?
    let gate: CatchGate

    func onActivate() {
        node.task {
            throw LoadFailed()
        } catch: { _ in
            gate.entered.signal()
            gate.proceed.wait()
            loadError = "failed"   // the model was removed while the handler ran
            gate.finished.signal()
        }
    }
}

// Without `.modelTesting`: the handler blocks its thread, which must not be the
// harness's executor.
struct RemovedModelCatchWriteTests {
    @Test func taskCatchHandlerRacingRemovalIsSilent() async {
        let gate = CatchGate()
        let root = CatchRoot(child: CatchChild(gate: gate)).withAnchor()
        let child = root.child!
        await Task.detached { gate.waitUntilEntered() }.value

        root.child = nil
        gate.proceed.signal()
        await Task.detached { gate.waitUntilFinished() }.value
        #expect(child.loadError == nil)
    }
}
