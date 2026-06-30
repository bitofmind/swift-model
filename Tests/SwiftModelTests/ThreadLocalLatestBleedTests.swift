import Foundation
import Testing
@testable import SwiftModel

// MARK: - Models mirroring StreamModel's exact init-accessor layout
//
// The device bug (two-week "stuck cyan"): inserting a NEW `StreamModel` sibling into
// the `streams` container during a live show nils an EXISTING, still-playing stream's
// `playerController` — with NO write through any per-property setter. The catch-all
// `Reference.state` didSet named the writer:
//
//   Reference.state.setter
//    ← _SourceBox._threadLocalStoreOrLatest          (ModelSourceBox.swift:408)
//    ← StreamModel.playerController (init-accessor)
//    ← StreamModel.init(id:config:)                  ← a NEW sibling being constructed
//    ← StreamsModel.updateSegments { … }
//
// Mechanism: the macro assigns init-accessor roles statically by declaration position
// (ModelTrackedMacro.swift:164-204): index-0 → `_threadLocalStoreFirst` (CLEARS the
// thread-local `latest`), middle → `_threadLocalStoreOrLatest` (if `latest != nil`,
// writes straight INTO that Reference), last → `_threadLocalStoreAndPop` (creates the
// Reference, SETS `latest = ref`). `latest` is a thread-local that PERSISTS between
// constructions — cleared only by the next construction's index-0 accessor. In a
// user-written `init` that assigns only some properties (the rest use defaults), a
// middle property's default-init accessor can fire while `latest` still holds a PRIOR
// construction's Reference → it writes its birth value into that unrelated, live model.

/// Optional `@Model` child — mirrors `MediaPlayerController`.
@Model private struct BleedController: Identifiable {
    let id: Int
}

/// Mirrors `StreamModel`'s layout: a `let id` first, several defaulted properties, an
/// optional `@Model` child in the middle, and a user-written `init` that assigns only
/// `id` + `config` (every other field uses its declaration default).
@Model private struct BleedStream: Identifiable {
    let id: Int                                // index-0 → _threadLocalStoreFirst (clears latest)
    var config: String                         // assigned in init
    var throttling: Int = 0
    var isMuted = false
    var isLoadingPlayer = false
    var playerController: BleedController? = nil   // MIDDLE optional @Model — the clobbered field
    var spareController: BleedController? = nil
    var marker: String = "birth"

    init(id: Int, config: String) {
        self.id = id
        self.config = config
        // playerController / spareController / marker all use their defaults
    }
}

@Model private struct BleedParent {
    var streams: [BleedStream] = []
}

// MARK: - Tests

/// Regression guard for the cross-construction thread-local `latest` bleed (RED before the
/// `_threadLocalStoreOrLatest` always-stack fix; green after).
///
/// Each test arranges for a live instance `A` to be the thread-local `latest` (i.e. the
/// most-recently-constructed `@Model` on this thread), then constructs a sibling `B` and
/// asserts `A`'s state was not corrupted by `B`'s construction. These are fully synchronous
/// (no clock, tasks, or concurrency) — the bug is a deterministic positional thread-local
/// logic error, not a data race.
@Suite(.modelTesting(exhaustivity: .off))
private struct ThreadLocalLatestBleedTests {

    /// MINIMAL, fully synchronous — no anchoring, no tasks, no clock. Proves the bleed is
    /// POSITIONAL (any MIDDLE property), not specific to `@Model` children or to concurrency.
    /// `throttling` is a middle property (`_threadLocalStoreOrLatest`); construct `A` with a
    /// non-default `throttling`, then construct `B` (which leaves `throttling` at its default
    /// 0). If `B`'s middle init-accessor adopts the stale `latest` (== `A`), it overwrites
    /// `A`'s value. Contrast `marker`, the LAST property (`_threadLocalStoreAndPop`), which is
    /// immune — see the assertion below.
    @Test func siblingConstructionCorruptsPriorInstanceMiddleField() async {
        let a = BleedStream(id: 1, config: "A")
        a.throttling = 7                               // pre-anchor write — does NOT touch `latest`
        a.marker = "live"
        #expect(a.throttling == 7 && a.marker == "live")

        // `A` is now the thread-local `latest`. Construct a sibling on the SAME thread.
        let b = BleedStream(id: 2, config: "B")
        _ = b

        #expect(a.throttling == 7, "sibling B's construction reset A.throttling (a MIDDLE field) via stale thread-local `latest`")
        #expect(a.marker == "live", "marker is the LAST property (immune) — if this fails the mechanism differs from expected")
    }

    /// The device shape: `A` holds a live optional `@Model` child (`playerController`).
    /// Constructing sibling `B` (whose `playerController` defaults to nil) must not nil A's.
    @Test func siblingConstructionDoesNotNilLiveOptionalModelChild() async {
        let a = BleedStream(id: 1, config: "A")
        a.playerController = BleedController(id: 99)    // constructing the child makes IT `latest`…
        // …so re-establish `A` as `latest` with a trivial pre-anchor write to a last-ish field.
        // (A plain write does not reset `latest`; only constructing a @Model does. We instead
        // construct A AFTER setting up — see the anchored variant below for the faithful case.)
        #expect(a.playerController?.id == 99)

        let b = BleedStream(id: 2, config: "B")
        _ = b

        #expect(a.playerController?.id == 99, "sibling B's construction niled A.playerController via stale `latest`")
    }

    /// Faithful to `StreamsModel.updateSegments`: a parent holds `[BleedStream]`; an existing
    /// element is live with its `playerController` set; a NEW sibling is inserted. The new
    /// element's `init` must not reach into the existing element's backing.
    ///
    /// Constructed so the existing element is the last `@Model` built on this thread before the
    /// insert (it IS `latest`), matching the device where mid=29 was the most-recently-added
    /// stream when the next `updateSegments` batch was constructed.
    @Test func containerInsertDoesNotCorruptExistingElement() async {
        let parent = BleedParent().withAnchor()

        // Build + insert the keeper, then set its child. The keeper's construction is the
        // last @Model built on this thread before the insert below.
        let keeper = BleedStream(id: 17, config: "keeper")
        keeper.marker = "playing"
        parent.streams.append(keeper)
        parent.streams.first(where: { $0.id == 17 })?.playerController = BleedController(id: 17_000)
        await expect { parent.streams.first(where: { $0.id == 17 })?.playerController?.id == 17_000 }

        // Insert a NEW sibling — its construction runs `playerController`'s init-accessor.
        parent.streams.append(BleedStream(id: 18, config: "new"))
        await settle()

        #expect(parent.streams.first(where: { $0.id == 17 })?.marker == "playing", "insert reset the existing element's marker")
        #expect(parent.streams.first(where: { $0.id == 17 })?.playerController?.id == 17_000,
                "inserting sibling 18 niled the live element 17's playerController via stale thread-local `latest`")
    }
}
