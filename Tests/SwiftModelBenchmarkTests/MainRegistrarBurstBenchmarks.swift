import Testing
import Foundation
import Observation
import Dependencies
@testable import SwiftModel

@Model private struct BurstModel: Sendable {
    var value: Int = 0
}

/// Off-main write burst against a model that has a **main** registrar (it was
/// tracked-read on the main thread), with the main actor free to drain.
///
/// Every such write must hand its main-registrar `willSet`/`didSet` to
/// `MainCallQueue`. This measures what that costs when the writer outruns the
/// drain: total wall-clock for the burst (writes + full drain) and the deepest
/// the queue got. Before coalescing the queue grew by one closure per write
/// (`max pending` tracked the burst size); after, it is bounded by the number
/// of distinct (context, property) pairs written between drains — here 1.
///
/// Numbers are printed, not asserted: this is a probe, not a regression gate.
@Suite(.serialized, .tags(.benchmark))
struct MainRegistrarBurstBenchmarks {

    @Test @MainActor func offMainBurstWithMainDraining() async {
        guard #available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *) else { return }
        let writes = 100_000
        let (model, anchor) = BurstModel().returningAnchor()
        defer { withExtendedLifetime(anchor) {} }

        // A tracked read on main creates the context's main registrar; from
        // here on every off-main write bridges through `mainCallQueue`.
        withObservationTracking { _ = model.value } onChange: {}
        let queue = model.modelContext.context!.mainCallQueue

        let maxPending = LockIsolated(0)
        let stop = LockIsolated(false)
        let sampler = Thread {
            while !stop.value {
                let n = queue.pendingCount
                maxPending.withValue { $0 = max($0, n) }
                usleep(50)
            }
        }
        sampler.start()

        let start = DispatchTime.now().uptimeNanoseconds
        await Task.detached {
            for _ in 0..<writes { model.value &+= 1 }
        }.value
        let writeNs = DispatchTime.now().uptimeNanoseconds &- start
        await queue.waitUntilIdle()
        let totalNs = DispatchTime.now().uptimeNanoseconds &- start
        stop.setValue(true)

        print(String(
            format: "  off-main burst of %d writes, main draining: writes %.1f ms (%.0f ns/write), drained %.1f ms, max pending %d",
            writes, Double(writeNs) / 1e6, Double(writeNs) / Double(writes), Double(totalNs) / 1e6, maxPending.value
        ))
        #expect(model.value == writes)
    }
}
