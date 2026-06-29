import Foundation
import Testing
@testable import SwiftModel

// MARK: - Recorder (external side-channel, survives any state reset)

/// Records per-stream lifecycle events from a place that the model's own state reset
/// cannot wipe. Keyed by the stream's Identifiable `id`.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func log(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        events.append(s)
    }

    func count(_ s: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return events.filter { $0 == s }.count
    }
}

// MARK: - Models mirroring the device scenario

/// Grandchild — the optional `@Model` child a stream sets from its activation task,
/// then parks observing. Mirrors `MediaPlayerController`.
@Model private struct ReanchorController: Identifiable {
    let id: Int
    var outcome: Int = 0
}

/// Child whose `onActivate` spawns ONE long-lived task that:
///   1. sets an optional `@Model` grandchild (`playerController`),
///   2. parks indefinitely in `for await … Observed { … }` (never returns for a
///      live element).
/// The only place `playerController` is niled is a `defer` that ALWAYS logs CLEARED.
@Model private struct ReanchorStream: Identifiable {
    let id: Int
    var isLoadingPlayer: Bool = false
    var playerController: ReanchorController? = nil
    var marker: String = "birth"      // a plain stored prop that must survive a sibling insert
    let recorder: Recorder

    func onActivate() {
        recorder.log("START \(id)")
        node.task {
            defer {
                playerController = nil
                recorder.log("CLEARED \(id)")
                recorder.log("EXIT \(id)")
            }
            // Bring the stream to its "playing" state: set the optional grandchild
            // and flip the loading flag, exactly as activateStream() does.
            isLoadingPlayer = true
            playerController = ReanchorController(id: id * 1000)
            marker = "playing"
            isLoadingPlayer = false
            recorder.log("SET \(id)")

            // Park forever observing the controller. `controller` is captured locally so the
            // stream never finishes even if the stored slot is wiped — mirrors the device
            // task that holds `controller 18` in scope.
            guard let controller = playerController else {
                recorder.log("LOST-CONTROLLER-IMMEDIATELY \(id)")
                return
            }
            for await _ in Observed(removeDuplicates: false, { controller.outcome }) {
                // never returns
            }
        } catch: { _ in }
    }
}

@Model private struct ReanchorParent {
    var streams: [ReanchorStream] = []
    let recorder: Recorder

    /// Build a fresh `ReanchorStream` for `id` — birth state (playerController == nil).
    func freshStream(_ id: Int) -> ReanchorStream { ReanchorStream(id: id, recorder: recorder) }
}

// MARK: - Tests

/// Regression suite for the reported "identified-collection reconcile resets an existing
/// element's stored state" bug (a `@Model` parent holding `[ChildModel]`, where a child's
/// `onActivate` task sets an optional `@Model` grandchild and parks in `for await Observed`).
///
/// **Findings.** The reconcile path is logically correct in every quiescent and serialized
/// shape (append, whole-array rebuild with fresh same-`id` instances, churn). The held child
/// keeps its identity, stored grandchild, and parked task — the fresh instance's birth state
/// is correctly ignored per the stable-identity contract.
///
/// The reported corruption only appears under genuinely concurrent, unsynchronized writers
/// (the field app drives `streams` from more than one task — "two RMW writers"). Run
/// `concurrentInsertWhilePlayingPreservesHeldChild` under ThreadSanitizer
/// (`swift test --sanitize=thread`): it surfaced a real production data race in
/// `Context.onActivate()` on `pendingActivation` — two concurrent collection writers each ran
/// the `structuralChange` re-activation loop in `_performCollectionSet` (which runs OUTSIDE the
/// state-transaction lock), racing on the unsynchronized `pendingActivation` `var`. That race is
/// now fixed (the value is read-and-niled under the hierarchy lock, consumed only by the single
/// winner of the atomic anchored→active transition).
@Suite(.modelTesting(exhaustivity: .off))
private struct ContainerReanchorResetTests {

    private func playing(_ s: ReanchorStream?) -> Bool { s?.playerController != nil && s?.marker == "playing" }

    /// APPEND a sibling (existing handles reused). Established behaviour — must preserve.
    @Test func siblingAppendPreservesHeldChild() async {
        let recorder = Recorder()
        let parent = ReanchorParent(streams: [ReanchorStream(id: 17, recorder: recorder)],
                                    recorder: recorder).withAnchor()
        await expect { playing(parent.streams.first(where: { $0.id == 17 })) }
        await settle()

        parent.streams.append(contentsOf: [parent.freshStream(18), parent.freshStream(19)])
        await settle()

        #expect(parent.streams.count == 3)
        #expect(playing(parent.streams.first(where: { $0.id == 17 })), "appended sibling reset the held child")
        #expect(recorder.count("CLEARED 17") == 0)
    }

    /// WHOLE-ARRAY REBUILD with FRESH instances reusing the existing `id` + new siblings.
    /// This mirrors a `updateSegments`-style `streams = sources.map { Stream(id: $0.id) }`.
    /// Per the stable-identity contract, the existing live child (id 17) must be CONTINUED:
    /// its context/task/state preserved and the fresh instance's birth state ignored.
    @Test func wholeArrayRebuildWithFreshInstancesPreservesHeldChild() async {
        let recorder = Recorder()
        let parent = ReanchorParent(streams: [ReanchorStream(id: 17, recorder: recorder)],
                                    recorder: recorder).withAnchor()
        await expect { playing(parent.streams.first(where: { $0.id == 17 })) }
        await settle()

        let mid = parent.streams.first(where: { $0.id == 17 })!.node.modelID

        // Rebuild: fresh birth instance for the EXISTING id 17, plus two new siblings.
        parent.streams = [parent.freshStream(17), parent.freshStream(18), parent.freshStream(19)]
        await settle()

        #expect(parent.streams.count == 3)
        let a = parent.streams.first(where: { $0.id == 17 })
        #expect(a != nil, "held child vanished on rebuild")
        #expect(a?.node.modelID == mid, "held child identity changed (not continued)")
        #expect(playing(a), "rebuild reset the held child to birth (playerController nil / marker birth)")
        #expect(recorder.count("CLEARED 17") == 0, "held child task was torn down")
        #expect(recorder.count("START 17") == 1, "held child re-activated")
    }

    /// CONCURRENT "actively playing" variant — closest to the device evidence.
    ///
    /// The keeper child (id 0) is actively "playing": a background task drives its
    /// `controller.outcome` so its parked `for await` is continuously receiving updates.
    /// Concurrently another task appends siblings. The device symptom is that the
    /// actively-playing child loses its stored `playerController` (while its task stays
    /// parked, no CLEARED/EXIT). Run under ThreadSanitizer + many iterations.
    @Test func concurrentInsertWhilePlayingPreservesHeldChild() async {
        let recorder = Recorder()
        let parent = ReanchorParent(streams: [ReanchorStream(id: 0, recorder: recorder)],
                                    recorder: recorder).withAnchor()
        await expect { playing(parent.streams.first(where: { $0.id == 0 })) }
        await settle()

        // "Playing": continuously bump the keeper's controller outcome.
        let player = Task.detached {
            for n in 1...400 {
                parent.streams.first(where: { $0.id == 0 })?.playerController?.outcome = n
            }
        }
        // Concurrently: append siblings (pool grows), as on device's updateSegments.
        let inserter = Task.detached {
            for i in 1...80 {
                parent.streams.append(parent.freshStream(i))
            }
        }
        // A SECOND concurrent RMW writer on the same array (mirrors the device's
        // "two RMW writers" — distinct tasks both doing read-modify-write on streams).
        let inserter2 = Task.detached {
            for i in 1...80 {
                parent.streams.append(parent.freshStream(i + 100_000))
            }
        }

        // Watch the keeper for a nil controller while all run.
        var sawNilController = false
        for _ in 0..<800 {
            if let a = parent.streams.first(where: { $0.id == 0 }), a.playerController == nil {
                sawNilController = true
                break
            }
            await Task.yield()
        }
        _ = await player.result
        _ = await inserter.result
        _ = await inserter2.result
        await settle()

        #expect(recorder.count("LOST-CONTROLLER-IMMEDIATELY 0") == 0, "keeper read its own controller back as nil")
        #expect(!sawNilController, "keeper lost its stored grandchild while playing during insert")
        #expect(playing(parent.streams.first(where: { $0.id == 0 })), "keeper reset to birth")
        #expect(recorder.count("CLEARED 0") == 0, "keeper task torn down")
        #expect(recorder.count("START 0") == 1, "keeper re-activated")
    }
}
