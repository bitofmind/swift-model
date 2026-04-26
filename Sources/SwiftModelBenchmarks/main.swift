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

func runAll() {
    benchActivation()
    benchPropertyAccess()
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
