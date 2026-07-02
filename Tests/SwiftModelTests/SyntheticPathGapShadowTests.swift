import Testing
import ConcurrencyExtras
import Observation
@testable import SwiftModel
import SwiftModel

// MARK: - Keys

private extension EnvironmentKeys {
    var gapCounter: EnvironmentStorage<Int> { .init(defaultValue: 0) }
}

private extension PreferenceKeys {
    var gapTotal: PreferenceStorage<Int> {
        .init(defaultValue: 0, key: "gapTotal") { $0 += $1 }
    }
}

// MARK: - Models

@Model
private struct EnvMemoModel {
    var scaled: Int {
        node.memoize(for: "scaled") {
            node.environment.gapCounter * 2
        }
    }
}

@Model
private struct NestedMemoModel {
    var value: Int = 0

    var inner: Int {
        node.memoize(for: "inner") { value * 2 }
    }

    var outer: Int {
        node.memoize(for: "outer") { inner + 1 }
    }
}

@Model
private struct PrefChildModel {
    var label: String = "child"
}

@Model
private struct PrefParentModel {
    var child: PrefChildModel = PrefChildModel()

    var total: Int {
        node.memoize(for: "total") { node.preference.gapTotal }
    }
}

// MARK: - Tests

/// Regression tests for the `withObservationTracking` gap-detector shadow covering
/// SYNTHETIC-path dependencies (memoize sentinels, environment storage, preferences).
///
/// Before the fix, the shadow `AccessCollector` (the persistent per-(context, path)
/// subscription closing Apple's one-shot registration gaps — Gaps A/B in
/// `ObservationTracking`) was dispatched only from `Context.willAccessDirect`, i.e.
/// only for real `_State` reads. Synthetic reads inside an `observe()` body
/// registered solely with Apple's one-shot tracking, so a synthetic-dependency write
/// landing between one-shot registration windows was silently dropped: the memoize's
/// dirty state was never bumped and every subsequent read returned the stale cached
/// value until some *other* tracked dependency changed.
///
/// The shadow's `onObservedChange` (which bumps the memoize `dirtyVersion` via
/// `didModify`) runs synchronously inside the writer's post-lock callbacks, so with
/// the fix the read on the line after a write is guaranteed to see the dirty state
/// and recompute — the synchronous `#expect`s below are deterministic, not timing-
/// dependent. On the old code they fail as soon as one write lands in a gap window.
///
/// The AccessCollector path (`UpdatePath.accessCollector`) was never affected (its
/// `context.onModify` subscriptions persist); it runs here as the behavioural
/// baseline both paths must match.
@Suite(.modelTesting(exhaustivity: .off))
struct SyntheticPathGapShadowTests {

    @Test(arguments: UpdatePath.allCases)
    func environmentDependencyIsNeverDropped(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { EnvMemoModel().withAnchor() }

        // First access sets up tracking (and, on the WOT path, the shadow's
        // persistent subscription on the typed `[_metadata:]` storage path).
        #expect(model.scaled == 0)

        for i in 1...300 {
            model.node.environment.gapCounter = i
            #expect(model.scaled == 2 * i, "environment write \(i) was dropped")
        }
        await settle()
    }

    @Test(arguments: UpdatePath.allCases)
    func preferenceDependencyIsNeverDropped(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { PrefParentModel().withAnchor() }

        // First access aggregates over self + descendants, registering the shadow's
        // subscription on each visited context's typed `[_preference:]` path.
        #expect(model.total == 0)

        for i in 1...300 {
            model.child.node.preference.gapTotal = i
            #expect(model.total == i, "preference contribution write \(i) was dropped")
        }
        await settle()
    }

    @Test(arguments: UpdatePath.allCases)
    func nestedMemoizeSentinelDependencyIsNeverDropped(updatePath: UpdatePath) async {
        let model = updatePath.withOptions { NestedMemoModel().withAnchor() }

        #expect(model.outer == 1)

        // The outer memoize depends on the inner memoize's *sentinel*
        // (`[memoizeKey:]`), whose dirty signal fires only when the inner
        // performUpdate commits a new value — convergence is asynchronous, so each
        // burst settles on the final expected value instead of asserting per write.
        // On the old code, a sentinel notification landing in the outer observer's
        // re-registration gap left `outer` stale forever and the settle timed out.
        for burst in 1...25 {
            let base = (burst - 1) * 8
            for step in 1...8 {
                model.value = base + step
            }
            await settle(model.outer == (base + 8) * 2 + 1)
        }
    }
}
