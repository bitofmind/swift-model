import Testing
import Observation
import IssueReporting
@testable import SwiftModel
import SwiftModel

// MARK: - Test models

@Model
private struct TraitCounter {
    var count: Int = 0
    enum Event { case incremented }

    func increment() {
        count += 1
        node.send(.incremented)
    }
}

@Model
private struct TraitLoader {
    var item: String? = nil
    var onLoad: @Sendable (String) -> Void = { _ in }

    func load(value: String) {
        item = value
        onLoad(value)
    }
}

// MARK: - ModelTestingTrait tests

@Suite(.modelTesting)
struct ModelTestingTraitTests {

    // Basic state + event assertion using global `expect { }`
    @Test func incrementUpdatesCount() async {
        let model = TraitCounter().withAnchor()
        model.increment()
        await expect {
            model.count == 1
            model.didSend(.incremented)
        }
    }

    // Multiple increments: each assert must consume all pending side effects.
    @Test func multipleIncrements() async {
        let model = TraitCounter().withAnchor()
        model.increment()
        await expect {
            model.count == 1
            model.didSend(.incremented)
        }
        model.increment()
        await expect {
            model.count == 2
            model.didSend(.incremented)
        }
    }

    // Exhaustivity off via nested trait: unhandled events are silently ignored.
    @Test(.modelTesting(exhaustivity: .off))
    func exhaustivityOffIgnoresUnhandledEvents() async {
        let model = TraitCounter().withAnchor()
        model.increment()  // state and event — both ignored at test end
    }

    // withAnchor connects via the recursive suite trait even without
    // an explicit @Test(.modelTesting) annotation on this function.
    @Test func withAnchorIsConnectedViaRecursiveSuiteTrait() async {
        let model = TraitCounter().withAnchor()
        model.increment()
        await expect {
            model.count == 1
            model.didSend(.incremented)
        }
    }

    // State-only exhaustivity via trait: events are not checked at test end.
    @Test(.modelTesting(exhaustivity: .state))
    func stateOnlyExhaustivity() async {
        let model = TraitCounter().withAnchor()
        model.increment()
        await expect(model.count == 1)
        // Event .incremented is sent but not asserted — OK because exhaustivity is [.state] only.
    }

    // Global `require(_:)` waits for an optional to become non-nil, stopping the test on failure.
    @Test func unwrapWaitsForOptional() async throws {
        let model = TraitLoader().withAnchor()
        model.load(value: "hello")
        let item = try await require(model.item)
        await expect {
            model.item == "hello"
            item == "hello"
        }
    }

    // TestProbe auto-installs on first call — no explicit install() needed.
    @Test func probeAutoInstallsOnFirstCall() async {
        let onLoad = TestProbe()
        let model = TraitLoader(onLoad: onLoad.call).withAnchor()
        model.load(value: "hello")
        await expect {
            model.item == "hello"
            onLoad.wasCalled(with: "hello")
        }
    }

    // TestProbe auto-registers for exhaustion checking on creation.
    // Allows the test to fail if the probe is never called at all.
    @Test func probeInstallRegistersForExhaustionCheck() async {
        let onLoad = TestProbe()
        let model = TraitLoader(onLoad: onLoad.call).withAnchor()
        // No explicit install() needed — probe auto-registers on creation.
        model.load(value: "world")
        await expect {
            model.item == "world"
            onLoad.wasCalled(with: "world")
        }
    }

    // TestProbe created before withAnchor() is buffered and flushed when withAnchor() registers.
    @Test func probeCreatedBeforeWithAnchor() async {
        let onLoad = TestProbe()
        // Probe is created here — before withAnchor() is called.
        // It should be buffered in the pending scope and flushed once the model is anchored.
        let model = TraitLoader(onLoad: onLoad.call).withAnchor()
        model.load(value: "buffered")
        await expect {
            model.item == "buffered"
            onLoad.wasCalled(with: "buffered")
        }
    }

    // wasCalled(with:) naming works as expected.
    @Test func probeWasCalledNaming() async {
        let onLoad = TestProbe()
        let model = TraitLoader(onLoad: onLoad.call).withAnchor()
        model.load(value: "hello")
        await expect {
            model.item == "hello"
            onLoad.wasCalled(with: "hello")
        }
    }

    // Suite exhaustivity (.full) narrowed at test level via .removing().
    @Test(.modelTesting(exhaustivity: .full.removing(.events)))
    func exhaustivityRemovingEvents() async {
        let model = TraitCounter().withAnchor()
        model.increment()
        // State must be consumed (still in exhaustivity), event is excluded.
        await expect(model.count == 1)
        // .incremented event is not asserted — OK because events are removed from exhaustivity.
    }

    // .off.adding(.state) — only state is checked, all other categories ignored.
    @Test(.modelTesting(exhaustivity: .off.adding(.state)))
    func exhaustivityAddingState() async {
        let model = TraitCounter().withAnchor()
        model.increment()
        await expect(model.count == 1)
        // .incremented event not asserted — fine, events not in exhaustivity.
    }

    // Modifier shorthand: .removing(.events) at test level applies relative to suite's .full.
    // Suite has .full, so this test gets .full − .events.
    @Test(.modelTesting(.removing(.events)))
    func exhaustivityModifierRemovingEvents() async {
        let model = TraitCounter().withAnchor()
        model.increment()
        await expect(model.count == 1)
        // .incremented event is not asserted — removed from exhaustivity by modifier.
    }

    // withExhaustivity scopes exhaustivity change for its body, then restores the original.
    @Test func withExhaustivityScoped() async {
        let model = TraitCounter().withAnchor()
        model.increment()
        await expect {
            model.count == 1
            model.didSend(.incremented)
        }
        // Inside withExhaustivity(.off), unasserted side effects are not failures.
        await withExhaustivity(.off) {
            model.increment()
            // count became 2 and .incremented was sent — not asserted, but that's fine
        }
        // After the block, full exhaustivity is restored. Consume remaining state + event.
        await expect {
            model.count == 2
            model.didSend(.incremented)
        }
    }

    // withExhaustivity modifier: .removing(.events) applied relative to current scope (.full).
    // Inside the block: .full − .events → events are not checked.
    // After the block: .full is restored → events ARE checked again.
    @Test func withExhaustivityModifierRemovingThenRestored() async {
        let model = TraitCounter().withAnchor()
        model.increment()
        await expect {
            model.count == 1
            model.didSend(.incremented)
        }
        await withExhaustivity(.removing(.events)) {
            model.increment()
            // event not consumed — OK because .events was removed
        }
        // After the block, exhaustivity is restored to .full. Consume state + event.
        await expect {
            model.count == 2
            model.didSend(.incremented)
        }
    }

    // A scope tracks one root, so a second withAnchor() in the same scope is reported
    // rather than silently dropped — naming both models and the ways out.
    @Test func secondWithAnchorInSameScopeIsReported() async {
        let model = TraitCounter().withAnchor()

        withKnownIssue {
            _ = TraitLoader().withAnchor()
        } matching: { issue in
            let text = issue.comments.map(\.rawValue).joined()
            return text.contains("withAnchor() was already called in this test scope")
                && text.contains("TraitCounter")       // the connected root
                && text.contains("TraitLoader")        // the rejected one
                && text.contains("returningAnchor()")  // the way out for a live peer
                && text.contains("withModelTesting")   // the way out for a later phase
        }

        // The scope's own root is unaffected by the rejected registration.
        model.increment()
        await expect {
            model.count == 1
            model.didSend(.incremented)
        }
    }

    // The way out the diagnostic points at: a nested scope gets its own root, which is
    // live and assertable for the duration of the closure.
    @Test func nestedWithModelTestingAnchorsItsOwnRoot() async {
        let model = TraitCounter().withAnchor()
        model.increment()
        await expect {
            model.count == 1
            model.didSend(.incremented)
        }

        await withModelTesting {
            let loader = TraitLoader().withAnchor()
            loader.load(value: "hello")
            await expect(loader.item == "hello")
        }
    }
}

// Nested-suite scope-composition tests:
//
// @Suite(.modelTesting(.removing(.events))) applies .full − .events as the suite baseline.
// Each @Test inside then applies its own modifier ON TOP of that baseline.
@Suite(.modelTesting(.removing(.events)))
struct NestedModifierTests {

    // No inner modifier: inherits suite's .full − .events baseline.
    // State must be consumed; events are excluded.
    @Test func inheritsBaseline() async {
        let model = TraitCounter().withAnchor()
        model.increment()
        await expect(model.count == 1)
        // .incremented event not consumed — fine, events excluded by suite modifier.
    }

    // Inner .removing(.state): applies on top of baseline (.full − .events) → .full − .events − .state.
    // Neither state nor events need to be asserted.
    @Test(.modelTesting(.removing(.state)))
    func composesRemoveState() async {
        let model = TraitCounter().withAnchor()
        model.increment()
        // Neither state nor events are checked — both removed by composition.
    }

    // Inner .adding(.events): applies on top of baseline (.full − .events) → .full.
    // Events are added BACK, so they must be consumed.
    @Test(.modelTesting(.adding(.events)))
    func composesAddEventsBack() async {
        let model = TraitCounter().withAnchor()
        model.increment()
        await expect {
            model.count == 1
            model.didSend(.incremented)
        }
        // Both state and events consumed — .adding(.events) restored them.
    }

    // withExhaustivity(.adding(.events)) inside a test that already excluded events:
    // Baseline: .full − .events. Inside the block: + .events → .full.
    // Events must be consumed inside the block.
    @Test func withExhaustivityAddsEventsBackInBlock() async {
        let model = TraitCounter().withAnchor()
        await withExhaustivity(.adding(.events)) {
            model.increment()
            await expect {
                model.count == 1
                model.didSend(.incremented)
            }
        }
        // After block, baseline (.full − .events) restored — no pending side effects here.
    }
}

// MARK: - Scope inheritance (`.inherited` default)

// Regression tests for the `withModelTesting` / `.modelTesting` defaults. The mechanism
// always read the enclosing scope (`_withModelTestingImpl` resolves against
// `_ModelTestingLocals.scope`), but the default argument used to be `.full` — an absolute
// preset that discards its base — so a nested scope that stated no opinion silently ran at
// full exhaustivity inside an `.off` suite. The default is now `.inherited`.
@Suite(.modelTesting(exhaustivity: .off))
struct NestedScopeInheritanceTests {

    // A bare nested scope inherits the suite's .off — the unhandled event is not reported.
    @Test func bareWithModelTestingInheritsSuiteOff() async {
        let reporter = CapturingIssueReporter()
        await withIssueReporters([reporter]) {
            await withModelTesting {
                let model = TraitCounter().withAnchor()
                model.increment()
                // Neither the state change nor the .incremented event is asserted.
            }
        }
        #expect(reporter.messages.isEmpty)
    }

    // A bare nested trait inherits too — same defect, same fix, via the trait path.
    @Test(.modelTesting) func bareNestedTraitInheritsSuiteOff() async {
        let model = TraitCounter().withAnchor()
        model.increment()
        // Nothing asserted; suite's .off is inherited rather than reset to .full.
    }

    // An explicit absolute preset still overrides the inherited value...
    @Test func explicitFullStillOverrides() async {
        let reporter = CapturingIssueReporter()
        await withIssueReporters([reporter]) {
            await withModelTesting(exhaustivity: .full) {
                let model = TraitCounter().withAnchor()
                model.increment()
            }
        }
        #expect(reporter.messages.contains { $0.contains("was not handled") })
    }

    // ...and when it does, the failure names the scope that set the policy. Without this
    // the message lands on the `withAnchor()` line and mentions neither the exhaustivity
    // nor its origin, which reads as if the suite trait had failed to apply.
    @Test func overridingScopeIsNamedInTheFailure() async {
        let reporter = CapturingIssueReporter()
        await withIssueReporters([reporter]) {
            await withModelTesting(exhaustivity: .full) {
                let model = TraitCounter().withAnchor()
                model.increment()
            }
        }
        let joined = reporter.messages.joined(separator: "\n")
        #expect(joined.contains("withModelTesting scope at"))
        #expect(joined.contains("overrides the enclosing scope's .off"))
    }

    // Any resolved value differing from the inherited one is annotated, not just .full.
    @Test func partialPresetOverrideIsAlsoAnnotated() async {
        let reporter = CapturingIssueReporter()
        await withIssueReporters([reporter]) {
            await withModelTesting(exhaustivity: .events) {
                let model = TraitCounter().withAnchor()
                model.increment()
            }
        }
        // .events differs from the inherited .off, so this one *is* annotated.
        #expect(reporter.messages.contains { $0.contains("withModelTesting scope at") })
    }
}

// A top-level scope with nothing to inherit from still defaults to full exhaustivity.
@Suite
struct TopLevelScopeDefaultTests {

    @Test func topLevelDefaultsToFull() async {
        let reporter = CapturingIssueReporter()
        await withIssueReporters([reporter]) {
            await withModelTesting {
                let model = TraitCounter().withAnchor()
                model.increment()
            }
        }
        #expect(reporter.messages.contains { $0.contains("was not handled") })
    }

    // Nothing was overridden, so no provenance note is attached.
    @Test func topLevelFailureCarriesNoProvenanceNote() async {
        let reporter = CapturingIssueReporter()
        await withIssueReporters([reporter]) {
            await withModelTesting {
                let model = TraitCounter().withAnchor()
                model.increment()
            }
        }
        #expect(!reporter.messages.contains { $0.contains("withModelTesting scope at") })
    }
}
