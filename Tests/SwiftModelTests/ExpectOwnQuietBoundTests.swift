import ConcurrencyExtras
import Foundation
import Testing
@testable import SwiftModel

@Model private struct BusyNeighbourModel {
    var ticks = 0

    func run(until stop: LockIsolated<Bool>) {
        node.task {
            // Real work on this scope's executor until told to stop, with a cap so an
            // unfixed run still ends. Wall-clock sleeps keep it far below the
            // runaway-resume bound.
            for _ in 0..<12_000 where !stop.value {
                try? await Task.sleep(nanoseconds: 5_000_000)
                ticks += 1
            }
        }
    }
}

@Model private struct QuietModel {
    var value = 0
}

@Suite(.modelTesting)
struct ExpectOwnQuietBoundTests {
    /// An unmet `expect` must fail on its own test's evidence, not wait for the whole
    /// process to go quiet. Here another `withModelTesting` scope stays busy for the
    /// whole wait, as the rest of a parallel run does. The expect used to fail only once
    /// every test in the process was quiet, so next to a busy neighbour it waited
    /// silently until the neighbour ended (in parallel-apple, past xcodebuild's
    /// 120 s per-test kill, with no message). The neighbour is stopped only after the
    /// expect returns, so it must still be running when the expect fails.
    @Test func unmetExpectFailsWhileAnotherTestIsBusy() async {
        let stop = LockIsolated(false)
        let neighbourStarted = LockIsolated(false)
        let neighbourEnded = LockIsolated(false)
        let neighbour = Task {
            await withModelTesting(.off) {
                let busy = BusyNeighbourModel().withAnchor()
                busy.run(until: stop)
                neighbourStarted.setValue(true)
                while !stop.value { try? await Task.sleep(nanoseconds: 10_000_000) }
            }
            neighbourEnded.setValue(true)
        }
        defer { stop.setValue(true) }
        while !neighbourStarted.value { try? await Task.sleep(nanoseconds: 1_000_000) }

        let model = QuietModel().withAnchor()
        await TestAccessOverrides.$expectOwnQuietBoundNanoseconds.withValue(200_000_000) {
            await withKnownIssue {
                await expect(model.value == 1)
            }
        }
        #expect(!neighbourEnded.value, "the expect waited for the busy neighbour to finish")
        stop.setValue(true)
        await neighbour.value
    }
}
