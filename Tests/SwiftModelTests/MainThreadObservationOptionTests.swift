import Testing
import ConcurrencyExtras
@testable import SwiftModel

/// Tests for `ModelOption.disableMainThreadObservation` and its interaction with the dual-
/// registrar observation pipeline.
///
/// The default behavior (option NOT set) maintains existing semantics on Apple platforms:
/// the main `ObservationRegistrar` receives `willSet`/`didSet` callbacks on the main thread
/// (via `mainCallQueue { @MainActor in ... }`) so SwiftUI/UIKit/AppKit consumers receive
/// observation notifications safely. Setting the option opts out of that bridge entirely —
/// no main registrar is created, no `mainCallQueue` work is enqueued, and only the
/// background registrar fires.
///
/// On non-Apple platforms (`!canImport(Darwin)`), `useMainThreadObservation` is forced to
/// `false` regardless of the option. There is no `Observable`-consuming UI framework on
/// Linux/Android/WASM, and on Android `@MainActor` work backed by libdispatch's main queue
/// never executes because Android's UI thread runs Android's `Looper` — so without the
/// forced-off behavior, `Observed { ... }` would silently lose all notifications from
/// background-thread mutations registered against the main registrar.
@Suite(.modelTesting(exhaustivity: .off))
struct MainThreadObservationOptionTests {

    /// Default (no option) on Apple platforms: main-thread observation is enabled.
    @Test func defaultEnabledOnApple() {
        let model = FlagProbe().withAnchor()
        #if canImport(Darwin)
        #expect(model.useMainThreadObservation == true)
        #else
        #expect(model.useMainThreadObservation == false)
        #endif
    }

    /// Setting the option disables main-thread observation on all platforms.
    @Test func optionDisablesOnAllPlatforms() {
        let model = withModelOptions([.disableMainThreadObservation]) {
            FlagProbe().withAnchor()
        }
        #expect(model.useMainThreadObservation == false)
    }

    /// Cross-thread mutation: with main-thread observation enabled (default on Apple),
    /// `Observed { ... }` registered while running on the main thread still receives
    /// updates when the property is mutated from a background task. This is the
    /// scenario the dual-registrar split was designed to support.
    ///
    /// On non-Apple, this test exercises the same code path; the assertion still holds
    /// because we now register against the background registrar (which fires
    /// synchronously on the mutating thread).
    ///
    /// Asserts on the post-mutation `snapshots.contains(_:)` rather than on the full
    /// array contents, because the initial-value fire races the first mutation and the
    /// resulting prefix isn't deterministic across runs/platforms — what matters for
    /// the regression is that *every* mutation produces a snapshot.
    @Test func observationFiresWhenMutatingFromBackgroundTask() async {
        let model = TopLevelModel().withAnchor()

        await Task.detached { model.counter = 5 }.value
        await expect { model.counter == 5 ; model.snapshots.contains(5) }

        await Task.detached { model.counter = 99 }.value
        await expect { model.counter == 99 ; model.snapshots.contains(99) }

        await Task.detached { model.counter = 42 }.value
        await expect { model.counter == 42 ; model.snapshots.contains(42) }
    }

    /// With `.disableMainThreadObservation` set, observation still fires for background-
    /// thread mutations — because we register against the background registrar in that mode,
    /// and its `willSet`/`didSet` fires synchronously on the mutating thread.
    @Test func observationFiresWithOptionDisabled() async {
        let model = withModelOptions([.disableMainThreadObservation]) {
            TopLevelModel().withAnchor()
        }

        await Task.detached { model.counter = 5 }.value
        await expect { model.counter == 5 ; model.snapshots.contains(5) }

        await Task.detached { model.counter = 99 }.value
        await expect { model.counter == 99 ; model.snapshots.contains(99) }
    }

    /// An `Observed { children.map(\.X) }` constructed inside `onActivate()` on a nested
    /// @Model fires for every mutation, regardless of platform. This is the exact shape
    /// that was silently failing on Android before the fix — registered against the main
    /// registrar while running on the JNI-called main thread, the queued `@MainActor`
    /// drain task never ran, so subsequent mutations from a background task were lost.
    @Test func nestedChildObservationFromOnActivate() async {
        let outer = OuterWithNestedObserver().withAnchor()

        await Task.detached { outer.inner.children[0].count = 5 }.value
        await expect { outer.inner.snapshots.contains([5, 0]) }

        await Task.detached { outer.inner.children[1].count = 99 }.value
        await expect { outer.inner.snapshots.contains([5, 99]) }
    }
}

// MARK: - Test models

/// Probe for the `useMainThreadObservation` flag — exposes the context-level state as a
/// regular property so tests can read it without touching internal `node` plumbing.
@Model private struct FlagProbe {
    /// Reads through to `AnyContext.useMainThreadObservation`. `@testable import SwiftModel`
    /// gives us access to the internal member.
    var useMainThreadObservation: Bool {
        node._$modelContext.context?.useMainThreadObservation ?? false
    }
}

@Model private struct TopLevelModel {
    var counter: Int = 0
    var snapshots: [Int] = []

    func onActivate() {
        node.task {
            for await snapshot in Observed(removeDuplicates: false, { counter }) {
                snapshots.append(snapshot)
            }
        }
    }
}

@Model private struct NestedChildModel {
    var count: Int = 0
}

@Model private struct NestedCollectionModel {
    var children: [NestedChildModel] = [NestedChildModel(), NestedChildModel()]
    var snapshots: [[Int]] = []

    func onActivate() {
        node.task {
            for await snapshot in Observed(removeDuplicates: false, { children.map(\.count) }) {
                snapshots.append(snapshot)
            }
        }
    }
}

@Model private struct OuterWithNestedObserver {
    var inner = NestedCollectionModel()
}
