import Testing
import Foundation
import ConcurrencyExtras
@testable import SwiftModel

// MARK: - Test types

/// A plain @ModelContainer enum with no associated values — equality is purely case-based.
@ModelContainer
private enum PlainStep: Equatable {
    case first
    case second
    case third
}

/// A @ModelContainer enum whose cases carry an Equatable associated value.
@ModelContainer
private enum EquatableStep: Equatable {
    case intro(URL)
    case home(Int)
}

/// A non-Equatable, non-Identifiable class that cannot be meaningfully compared.
/// Analogous to AVPlayer: identity comparison is meaningless for value-change detection.
private final class NonEquatablePlayer: @unchecked Sendable {}

/// A @ModelContainer enum whose case carries a non-Equatable, non-Identifiable associated value.
/// @ModelContainer synthesises `==` via _modelEqual; the unconstrained fallback returns `false`
/// for `NonEquatablePlayer`, so `.intro(samePlayer) == .intro(samePlayer)` is always `false`.
/// `.done == .done` is `true` because there is no associated value to compare.
@ModelContainer
private enum PlayerStep {
    case intro(NonEquatablePlayer)
    case done
}

// MARK: - containerIsSame unit tests

/// Direct tests of the `containerIsSame` function for @ModelContainer enums.
@Suite("containerIsSame — @ModelContainer enums")
struct ContainerIsSameEnumTests {

    // MARK: Plain enum (no associated values)

    @Test("same case → true")
    func plainEnumSameCaseIsTrue() {
        #expect(containerIsSame(PlainStep.first, PlainStep.first))
        #expect(containerIsSame(PlainStep.second, PlainStep.second))
    }

    @Test("different case → false")
    func plainEnumDifferentCaseIsFalse() {
        #expect(!containerIsSame(PlainStep.first, PlainStep.second))
        #expect(!containerIsSame(PlainStep.second, PlainStep.third))
    }

    // MARK: Enum with Equatable associated values

    @Test("same case + same Equatable AV → true")
    func equatableAVSameValueIsTrue() {
        let url = URL(string: "https://example.com")!
        #expect(containerIsSame(EquatableStep.intro(url), EquatableStep.intro(url)))
        #expect(containerIsSame(EquatableStep.home(42), EquatableStep.home(42)))
    }

    @Test("same case + different Equatable AV → false")
    func equatableAVDifferentValueIsFalse() {
        let url1 = URL(string: "https://a.com")!
        let url2 = URL(string: "https://b.com")!
        #expect(!containerIsSame(EquatableStep.intro(url1), EquatableStep.intro(url2)))
        #expect(!containerIsSame(EquatableStep.home(1), EquatableStep.home(2)))
    }

    @Test("different case → false")
    func equatableAVDifferentCaseIsFalse() {
        let url = URL(string: "https://example.com")!
        #expect(!containerIsSame(EquatableStep.intro(url), EquatableStep.home(1)))
    }

    // MARK: Enum with non-Equatable, non-Identifiable associated value

    /// Known behaviour: the _modelEqual fallback returns `false` for types that are neither
    /// Equatable nor Identifiable (e.g. AVPlayer-like classes). This means
    /// `.intro(samePlayer) == .intro(samePlayer)` is always `false` — every write to an
    /// `.intro` property triggers a re-render regardless of whether the instance changed.
    ///
    /// Cases with no associated values (`.done`) compare as expected — same case is `true`.
    @Test("non-Equatable AV: intro case always returns false (known behaviour)")
    func nonEquatableAVIntroAlwaysFalse() {
        let player = NonEquatablePlayer()
        let player2 = NonEquatablePlayer()
        // Same instance → still false (can't compare the non-Equatable AV)
        #expect(!containerIsSame(PlayerStep.intro(player), PlayerStep.intro(player)))
        // Different instances → also false
        #expect(!containerIsSame(PlayerStep.intro(player), PlayerStep.intro(player2)))
        // Bare case (no AV) → correctly true
        #expect(containerIsSame(PlayerStep.done, PlayerStep.done))
    }
}

// MARK: - Observation tests

@Model
private struct StepModel {
    var step: EquatableStep = .home(0)
    var changeCount: Int = 0

    func onActivate() {
        node.onChange(of: step, initial: false) { _, _ in
            changeCount += 1
        }
    }
}

@Suite(.modelTesting)
struct ModelContainerEnumObservationTests {

    /// Observation fires when the enum switches to a different case.
    @Test func observationFiresOnCaseChange() async {
        let model = StepModel().withAnchor()
        await settle {}  // let onActivate complete and register onChange

        let url = URL(string: "https://example.com")!
        model.step = .intro(url)
        await expect {
            model.step == .intro(url)
            model.changeCount == 1
        }

        model.step = .home(99)
        await expect {
            model.step == .home(99)
            model.changeCount == 2
        }
    }

    /// Observation fires when an Equatable associated value changes within the same case.
    @Test func observationFiresOnAssociatedValueChange() async {
        let model = StepModel().withAnchor()
        await settle {}

        model.step = .intro(URL(string: "https://a.com")!)
        await expect {
            model.step == .intro(URL(string: "https://a.com")!)
            model.changeCount == 1
        }

        model.step = .intro(URL(string: "https://b.com")!)
        await expect {
            model.step == .intro(URL(string: "https://b.com")!)
            model.changeCount == 2
        }
    }

    /// After the containerIsSame fix, writing the same enum value (same case, same Equatable
    /// associated value) must NOT fire a spurious onChange notification.
    @Test func noSpuriousObservationOnSameValue() async {
        let url = URL(string: "https://example.com")!
        let model = StepModel().withAnchor()
        await settle {}

        model.step = .intro(url)
        await expect {
            model.step == .intro(url)
            model.changeCount == 1
        }

        // Same-value writes are suppressed by containerIsSame: no modification records,
        // no onChange callbacks, no exhaustivity entries.
        model.step = .intro(url)
        model.step = .intro(url)

        #expect(model.changeCount == 1, "Redundant writes to same enum value must not fire onChange")
    }

    /// Writing a different case always fires onChange, even after a suppressed same-value write.
    @Test func observationFiresAfterSameValueThenDifferentCase() async {
        let url = URL(string: "https://example.com")!
        let model = StepModel().withAnchor()
        await settle {}

        model.step = .intro(url)
        await expect {
            model.step == .intro(url)
            model.changeCount == 1
        }

        model.step = .intro(url)    // same — suppressed, no modification record
        model.step = .home(42)      // different case — must fire
        await expect {
            model.step == .home(42)
            model.changeCount == 2
        }
    }
}

// MARK: - AccessCollector limitation documentation

/// Documents the known limitation of the iOS 16 AccessCollector path:
/// properties accessed only inside a lazy @ViewBuilder closure passed to a child view
/// are NOT registered as dependencies, because the closure executes after the
/// AccessCollector window for the parent view's `body` has already closed.
///
/// The withObservationTracking path (iOS 17+) does not have this limitation —
/// it tracks all accesses on the same runloop turn regardless of closure nesting.
///
/// **Downstream fix**: in views affected by this, capture the model property
/// in a local `let` binding at the top of `body` so the AccessCollector registers it:
///
/// ```swift
/// var body: some View {
///     let step = model.step   // captured here → AccessCollector registers the dependency
///     return ModalContext {
///         switch step { ... }  // use the captured value inside the lazy closure
///     }
/// }
/// ```
///
/// This test suite has no automated tests for the AccessCollector limitation because
/// it only manifests during SwiftUI rendering (when AccessCollector is the active ModelAccess).
/// The observation tests above (using onChange/Observed) always track correctly regardless.
@Suite("AccessCollector lazy-closure limitation — documented")
struct AccessCollectorLimitationTests {

    /// Verifies that the iOS 17+ withObservationTracking path correctly tracks a property
    /// that is accessed inside a deferred closure — i.e., the limitation does NOT apply there.
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    @Test func withObservationTrackingTracksLazyClosureAccess() async {
        let model = StepModel().withAnchor()
        let url = URL(string: "https://example.com")!
        let fired = LockIsolated(false)

        withObservationTracking {
            // Simulate a lazy closure: step is only read when the inner closure is called,
            // not at tracking-setup time. withObservationTracking still registers the dep.
            let lazyAccess: () -> EquatableStep = { model.step }
            _ = lazyAccess()
        } onChange: {
            fired.setValue(true)
        }

        model.step = .intro(url)
        await Task.yield()
        #expect(fired.value, "withObservationTracking must track properties accessed inside nested closures")
    }
}
