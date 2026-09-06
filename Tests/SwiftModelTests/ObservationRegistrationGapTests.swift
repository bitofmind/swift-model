import Testing
import Foundation
import Observation
import ConcurrencyExtras
@testable import SwiftModel
import SwiftModel

@Model private struct GapCounter: Sendable {
    var count = 0
}

/// Pins the access-before-read invariant of a tracked read (`Context.trackedRead`).
///
/// `withObservationTracking` is one-shot: the registrar records what the body touched and
/// fires `onChange` on the first later write. If the read path registered its access with
/// the registrar *after* projecting the value out of the locked state, a writer on another
/// thread could land its `willSet`/`didSet` in between — nobody is registered yet, so
/// nothing fires — and the body would return a value that is already stale with no
/// invalidation ever arriving. Apple's own `@Observable` accessors register before they
/// return the value for exactly this reason, and so must we: the registration must happen
/// before the hierarchy lock is taken for the projection.
///
/// The test races one reader (a tracking body reading `count`) against one writer (a single
/// `count += 1` after a small randomised delay), many times. Whenever the body saw the old
/// value, the write happened after the read, so `onChange` MUST have fired by the time the
/// writer returns (the background registrar notifies synchronously on the writing thread).
/// A registration gap shows up as `sawOld && !fired`.
struct ObservationRegistrationGapTests {

    @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
    @Test func trackingRegistersBeforeTheValueIsRead() {
        let iterations = 3000
        var gaps = 0
        var raced = 0  // iterations where the body saw the old value (the write came after)

        for i in 0..<iterations {
            let (model, anchor) = GapCounter().returningAnchor()
            let fired = LockIsolated(false)
            let seen = LockIsolated(-1)
            let go = LockIsolated(false)
            // Randomise who gets to the model first, on a nanosecond scale: both sides
            // spin a random number of iterations after the start flag flips.
            let readerSpin = Int.random(in: 0..<400)
            let writerSpin = Int.random(in: 0..<400)

            DispatchQueue.concurrentPerform(iterations: 3) { thread in
                switch thread {
                case 0:
                    go.setValue(true)
                case 1:
                    while !go.value {}
                    var sink = 0
                    for k in 0..<readerSpin { sink &+= k }
                    let zero = sink & 0
                    withObservationTracking {
                        seen.setValue(model.count &+ zero)
                    } onChange: {
                        fired.setValue(true)
                    }
                default:
                    while !go.value {}
                    var sink = 0
                    for k in 0..<writerSpin { sink &+= k }
                    model.count += 1 &+ (sink & 0)
                }
            }

            let final = withUntrackedModelReads { model.count }
            let sawOld = seen.value != final
            if sawOld {
                raced += 1
                if !fired.value { gaps += 1 }
            }
            withExtendedLifetime(anchor) {}
            _ = i
        }

        #expect(raced > 0, "the race never put the write after the read; the test did not exercise the gap")
        #expect(gaps == 0, "\(gaps) of \(raced) read-before-write iterations returned a stale value with no onChange (\(iterations) total)")
    }
}
