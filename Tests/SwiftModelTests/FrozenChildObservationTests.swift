import Foundation
import Testing
import ConcurrencyExtras
@testable import SwiftModel

/// Characterises the live-vs-frozen observation contract that underpins the
/// `imagien-apple` "sub-view stuck on a child's birth state" investigation (the
/// framework fix landed in #26 — the optional/`ModelContainer` same-`id` unanchored
/// bug). These tests pin down *why* a non-live `@Model` value silently fails to
/// drive a SwiftUI view, so a regression in either direction is caught:
///
/// 1. A child `@Model` read out of a *live* anchored parent is itself **live**
///    (`context != nil`, `lifetime == .active`) and tracks subsequent mutations —
///    the normal read path never hands a frozen copy to a sub-view.
/// 2. A **frozen copy** (`.frozenCopy`, `context == nil`, same `modelID`) silently
///    drops out of *all* observation: it does not participate in Apple's
///    `withObservationTracking` (the iOS 17+ registrar path SwiftUI uses), so a view
///    holding one never re-renders — it is pinned to the snapshot. This is the
///    mechanism behind the "stuck at birth state" symptom, and the reason a non-live
///    value must never reach an `@ObservedModel`.
@Suite(.modelTesting)
struct FrozenChildObservationTests {
    // (1) A child read out of a live parent is live and tracks live mutations.
    @Test func childValueReadFromParentIsLiveAndTracks() async {
        let p = FCParent(children: [FCChild(id: 1)]).withAnchor()
        await settle {}
        let child = p.children.first { $0.id == 1 }!
        #expect(child.context != nil)
        #expect(child.lifetime == .active)
        p.children[0].flag = true
        await expect { p.children[0].flag == true }
        await expect { child.flag == true }   // the handed-down value tracks live
    }

    // (2) A frozen copy is non-live, shares the modelID, and never sees live writes.
    @Test func frozenChildIsNonLiveAndDoesNotTrack() async {
        let p = FCParent(children: [FCChild(id: 1)]).withAnchor()
        await settle {}
        let live = p.children.first { $0.id == 1 }!
        let frozen = live.frozenCopy
        #expect(frozen.lifetime == .frozenCopy)
        #expect(frozen.context == nil)
        #expect(frozen.modelID == live.modelID)   // same instance identity
        p.children[0].flag = true
        await expect { p.children[0].flag == true }
        await settle {}
        #expect(frozen.flag == false)   // frozen snapshot never advances
    }

    // (3) The registrar path SwiftUI uses: a live child drives
    // `withObservationTracking` (→ re-render); a frozen copy does NOT.
    // This is the mechanism behind the "stuck on birth state" symptom.
    @available(macOS 14.0, iOS 17.0, *)
    @Test func registrarTrackingLiveVsFrozen() async {
        let p = FCParent(children: [FCChild(id: 1)]).withAnchor()
        await settle {}
        let live = p.children.first { $0.id == 1 }!
        let frozen = live.frozenCopy

        let liveFired = LockIsolated(false)
        let frozenFired = LockIsolated(false)

        withObservationTracking {
            _ = live.flag
        } onChange: {
            liveFired.setValue(true)
        }
        withObservationTracking {
            _ = frozen.flag
        } onChange: {
            frozenFired.setValue(true)
        }

        p.children[0].flag = true
        await expect { p.children[0].flag == true }
        await settle {}
        #expect(liveFired.value == true)    // live child → SwiftUI re-render
        #expect(frozenFired.value == false) // frozen copy → silently never updates
    }

    // (4) Public `modelID` exposes instance identity even when the model declares an
    // explicit, reusable domain `id` that shadows the default `Identifiable.id`.
    @Test func publicModelIDDistinguishesInstancesSharingDomainID() async {
        let p = FCParent(children: [FCChild(id: 1)]).withAnchor()
        await settle {}
        let child = p.children.first { $0.id == 1 }!
        #expect(child.id == 1)                       // domain id (Identifiable.id)
        // A second, distinct instance reusing the same domain id has a different
        // instance identity — only reachable via `modelID`.
        let other = FCChild(id: 1).withAnchor()
        await settle {}
        #expect(other.id == child.id)                // domain ids match
        #expect(other.modelID != child.modelID)      // instances differ
    }
}

@Model fileprivate struct FCParent { var children: [FCChild] = [] }
@Model fileprivate struct FCChild { let id: Int; var sub: FCSub? = nil; var flag: Bool = false }
@Model fileprivate struct FCSub { var ready: Bool = false }
