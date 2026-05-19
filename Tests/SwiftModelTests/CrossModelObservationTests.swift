import Foundation
import Testing
@testable import SwiftModel

/// Regression suite for cross-@Model `Observed { ... }` propagation. Started as
/// a candidate reproducer for a gap reported by the `imagien-apple` project on
/// Android (Swift 6.3 OSS toolchain, Android SDK) — but the bug was NOT
/// reproducible. Keeping the tests as a regression net.
///
/// **Empirical findings (2026-05-18)**:
/// - All 6 tests below PASS on macOS (both code paths).
/// - The same scenarios run as a standalone executable on the Android emulator
///   (via Swift 6.3 cross-compile + adb push + LD_LIBRARY_PATH) also PASS.
/// - Including the closest-to-imagien shape:
///   `Observed { streams.map { $0.computedReadingChild } }` over
///   `IdentifiedArrayOf<Stream<C>>` (generic), with a computed property on
///   each Stream reading from its optional `Controller?` child @Model.
///
/// The imagien team's "Observed fires only once on Android" was likely the
/// downstream effect of a separate bug they fixed (lazy `preparePlayer` —
/// streams weren't actually transitioning state on Android because their
/// underlying ExoPlayer wasn't being prepared, so the observation correctly
/// didn't fire).
///
/// Field symptom: a `StreamModel` references a separate `MediaPlayerController`
/// @Model via an optional stored property
/// (`var playerController: MediaPlayerController? = nil`). Reading
/// `playerController?.state` from an `Observed { ... }` closure does NOT
/// re-fire when `controller.state` changes — the observation appears to fire
/// only once at initial subscription. The team worked around this by mirroring
/// each consumed child property into a stored field on the parent
/// (`mirroredX`) via `node.onChange(of: controller.X) { _, v in mirroredX = v }`.
///
/// Two code paths in swift-model handle observation:
///
/// 1. **`withObservationTracking` (default)**: uses Apple's `Observation`
///    framework. `if #available(macOS 14, iOS 17, …, *)` returns true on
///    Android (via the `*` clause), so this path IS the one imagien hits in
///    production. The `_$modelContext`'s `useObservationRegistrar` defaults
///    to true. NOTE: `shouldEnableMainThreadObservation` returns false on
///    non-Apple via `#if canImport(Darwin)` — Android always uses the
///    background registrar.
///
/// 2. **`AccessCollector` (opt-in)**: forced via
///    `.disableObservationRegistrar`. Pre-iOS-17 fallback and explicit opt-out
///    path.
///
/// The tests run each scenario under BOTH paths. If the `withObservationTracking`
/// variant fails on Android but the `AccessCollector` variant passes (or vice
/// versa), we know which underlying mechanism breaks.
@Model fileprivate struct CrossObsParent {
    var child: CrossObsChild? = nil
    /// Snapshots collected from an `Observed { child?.x }` running on
    /// the parent's activation task.
    var snapshots: [Int?] = []

    func onActivate() {
        node.task {
            for await x in Observed(removeDuplicates: false, { child?.x }) {
                snapshots.append(x)
            }
        }
    }
}

@Model fileprivate struct CrossObsChild {
    var x: Int = 0
}

@Model fileprivate struct CrossObsParentDirect {
    var value: Int = 0
    var snapshots: [Int] = []
    func onActivate() {
        node.task {
            for await v in Observed(removeDuplicates: false, { value }) {
                snapshots.append(v)
            }
        }
    }
}

@Suite(.modelTesting(exhaustivity: .off)) struct CrossModelObservationTests {

    // MARK: - withObservationTracking path (default, what Android actually hits)

    @Test func observedFiresForParentStoredProperty_withObservationTracking() async {
        let model = CrossObsParentDirect().withAnchor()
        model.value = 1
        model.value = 2
        model.value = 3
        await expect { model.snapshots.contains(3) }
    }

    @Test func observedFiresForChildStoredPropertyViaParent_withObservationTracking() async {
        let model = CrossObsParent().withAnchor()
        model.child = CrossObsChild()
        model.child?.x = 1
        model.child?.x = 2
        model.child?.x = 3
        await expect { model.snapshots.contains(3) }
    }

    @Test func observedFiresForGrandchildPropertyViaArrayMap_withObservationTracking() async {
        let model = CrossObsContainer(streams: [
            CrossObsStream(controller: CrossObsCtrl(value: 0)),
            CrossObsStream(controller: CrossObsCtrl(value: 0)),
        ]).withAnchor()
        model.streams[1].controller?.value = 7
        model.streams[1].controller?.value = 8
        model.streams[1].controller?.value = 9
        await expect { model.snapshots.contains(where: { $0.contains(9) }) }
    }

    // MARK: - AccessCollector path (forced via .disableObservationRegistrar)

    @Test func observedFiresForParentStoredProperty_accessCollector() async {
        let model = withModelOptions([.disableObservationRegistrar]) {
            CrossObsParentDirect().withAnchor()
        }
        model.value = 1
        model.value = 2
        model.value = 3
        await expect { model.snapshots.contains(3) }
    }

    @Test func observedFiresForChildStoredPropertyViaParent_accessCollector() async {
        let model = withModelOptions([.disableObservationRegistrar]) {
            CrossObsParent().withAnchor()
        }
        model.child = CrossObsChild()
        model.child?.x = 1
        model.child?.x = 2
        model.child?.x = 3
        await expect { model.snapshots.contains(3) }
    }

    @Test func observedFiresForGrandchildPropertyViaArrayMap_accessCollector() async {
        let model = withModelOptions([.disableObservationRegistrar]) {
            CrossObsContainer(streams: [
                CrossObsStream(controller: CrossObsCtrl(value: 0)),
                CrossObsStream(controller: CrossObsCtrl(value: 0)),
            ]).withAnchor()
        }
        model.streams[1].controller?.value = 7
        model.streams[1].controller?.value = 8
        model.streams[1].controller?.value = 9
        await expect { model.snapshots.contains(where: { $0.contains(9) }) }
    }
}

@Model fileprivate struct CrossObsContainer {
    var streams: [CrossObsStream] = []
    var snapshots: [[Int]] = []
    func onActivate() {
        node.task {
            for await values in Observed(removeDuplicates: false, {
                streams.map { $0.controller?.value ?? -1 }
            }) {
                snapshots.append(values)
            }
        }
    }
}

@Model fileprivate struct CrossObsStream: Identifiable {
    let id = UUID()
    var controller: CrossObsCtrl? = nil
}

@Model fileprivate struct CrossObsCtrl: Identifiable {
    let id = UUID()
    var value: Int = 0
}
