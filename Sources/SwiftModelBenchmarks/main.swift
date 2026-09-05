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
if #available(macOS 15.0, *) {
    if let i = CommandLine.arguments.firstIndex(of: "--profile") {
        let name = CommandLine.arguments[i + 1], n = Int(CommandLine.arguments[i + 2])!
        Thread { profileScenario(name, threads: n); exit(0) }.start()
        dispatchMain()
    }
    if CommandLine.arguments.contains("--contention") {
        Thread { benchContention(); exit(0) }.start()
        dispatchMain()
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
