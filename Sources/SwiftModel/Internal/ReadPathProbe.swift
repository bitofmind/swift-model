import Foundation

// PROTOTYPE PROBE — measures the read path from *inside* the SwiftModel module,
// where whole-module optimization can specialize and inline the entire chain
// (macro accessor → _ModelSourceBox subscript → willAccessDirect → Context
// subscript). Cross-module clients instead call unspecialized generic entry
// points; the delta between this probe and the executable's section 2b numbers
// is therefore the upper bound on what an @inlinable/@usableFromInline surface
// could recover for clients. Not intended to ship.
//
// WASI has no libdispatch (`DispatchTime`), and the probe is only consumed by
// the macOS benchmark executable anyway.
#if !os(WASI)

@Model struct _ReadProbeModel: Sendable {
    var value = 0
}

nonisolated(unsafe) private var _probeSink = 0

public func _readPathProbe(iterations: Int) -> (tracked: Double, untracked: Double) {
    let model = _ReadProbeModel().withAnchor()
    for _ in 0..<10_000 { _probeSink &+= model.value }

    var start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { _probeSink &+= model.value }
    let tracked = Double(DispatchTime.now().uptimeNanoseconds &- start) / Double(iterations)

    start = DispatchTime.now().uptimeNanoseconds
    withUntrackedModelReads {
        for _ in 0..<iterations { _probeSink &+= model.value }
    }
    let untracked = Double(DispatchTime.now().uptimeNanoseconds &- start) / Double(iterations)

    return (tracked, untracked)
}

#endif
