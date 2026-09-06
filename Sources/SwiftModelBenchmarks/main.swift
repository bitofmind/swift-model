import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// SwiftModel Benchmarks
//
// Usage:
//   # Run once and print a timing report:
//   swift run -c release SwiftModelBenchmarks
//
//   # Loop forever — attach Instruments (Time Profiler / Allocations) to the
//   # process PID shown at startup, then stop it with Ctrl-C when you have
//   # enough samples:
//   swift run -c release SwiftModelBenchmarks --loop
//
//   # Contention / scaling tables (ns per op per thread at 1/2/4/8 threads),
//   # and a single-row loop to profile under `sample` / Instruments:
//   swift run -c release SwiftModelBenchmarks --contention
//   swift run -c release SwiftModelBenchmarks --profile "c3 tracked read distinct trees" 8
//
//   # Off-main write burst to one main-tracked model, main draining vs blocked:
//   swift run -c release SwiftModelBenchmarks --burst
//
//   # Or build first, then profile with xctrace directly:
//   swift build -c release --product SwiftModelBenchmarks
//   xcrun xctrace record \
//     --template 'Time Profiler' \
//     --launch -- .build/release/SwiftModelBenchmarks --loop
// ─────────────────────────────────────────────────────────────────────────────

let loopMode = CommandLine.arguments.contains("--loop")

print("SwiftModel Benchmarks")
print("Build: \(loopMode ? "loop mode (attach Instruments now, PID \(ProcessInfo.processInfo.processIdentifier))" : "single pass")")
if loopMode {
    print("Press Ctrl-C to stop.\n")
}

// Contention probes run OFF the main thread so the MainActor can drain
// SwiftModel's main-registrar notification queue — see ContentionBenchmarks.swift.
//
// The main thread must service the main queue through its run loop, NOT
// `dispatchMain()`: that call parks the real main thread in `sigsuspend` and hands
// the main queue to an ordinary worker thread, on which `Thread.isMainThread`
// (`pthread_main_np`) is false. SwiftModel gates its main-registrar bridging on
// that check, so under `dispatchMain()` a "tracked read on main" registers with
// the background registrar instead, no model ever gets a main registrar, and the
// off-main enqueue path these probes exist to measure is never taken.
@available(macOS 15.0, *)
func runOffMain(_ body: @escaping @Sendable () -> Void) -> Never {
    Thread { body(); exit(0) }.start()
    // A run loop with no sources returns at once; a far-future timer keeps it alive.
    RunLoop.main.add(Timer(timeInterval: 3600, repeats: true) { _ in }, forMode: .default)
    RunLoop.main.run()
    fatalError("main run loop exited")
}

if #available(macOS 15.0, *) {
    if let i = CommandLine.arguments.firstIndex(of: "--profile") {
        let name = CommandLine.arguments[i + 1], n = Int(CommandLine.arguments[i + 2])!
        runOffMain { profileScenario(name, threads: n) }
    }
    if CommandLine.arguments.contains("--contention") {
        runOffMain { benchContention() }
    }
    if CommandLine.arguments.contains("--burst") {
        runOffMain { benchBurst() }
    }
}

func runAll() {
    benchActivation()
    benchPropertyAccess()
    benchReadPath()
    benchModelScan()
    benchParallelReads()
    benchInModuleProbe()
    benchPropertyAccessWithObserver()
    benchEventDispatch()
    benchHierarchyMutation()
    benchArrayHierarchyMutation()
    benchContainerValueUpdate()
    benchContainerCollectionMutation()
    benchDependencyAccess()
    benchAnchorDependencies()
    print("")
}

if loopMode {
    while true { runAll() }
} else {
    runAll()
}
