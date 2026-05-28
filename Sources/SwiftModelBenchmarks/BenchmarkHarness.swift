import Foundation

// MARK: - Timing

struct BenchmarkResult {
    let name: String
    let iterations: Int
    let nanos: UInt64

    var nsPerOp: Double { Double(nanos) / Double(iterations) }
    var usPerOp: Double { nsPerOp / 1_000 }
    var msTotal: Double { Double(nanos) / 1_000_000 }
}

/// Measures the wall-clock time to run `body` `iterations` times.
/// Warms up with `warmup` iterations first (default: 5% of iterations, min 100).
@discardableResult
func measure(
    _ name: String,
    iterations: Int,
    warmup: Int? = nil,
    body: () -> Void
) -> BenchmarkResult {
    let warmupCount = warmup ?? max(iterations / 20, 100)
    for _ in 0..<warmupCount { body() }

    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<iterations { body() }
    let elapsed = DispatchTime.now().uptimeNanoseconds &- start

    let result = BenchmarkResult(name: name, iterations: iterations, nanos: elapsed)
    printResult(result)
    return result
}

func printResult(_ r: BenchmarkResult) {
    let nameCol  = r.name.padding(toLength: 46, withPad: " ", startingAt: 0)
    let iterStr  = formatCount(r.iterations)
    let iterCol  = iterStr.leftPad(toLength: 10)
    let nsStr    = String(format: "%.1f", r.nsPerOp)
    let nsCol    = nsStr.leftPad(toLength: 10)
    let totalStr = String(format: "%.1f ms", r.msTotal)
    print("  \(nameCol) \(iterCol) iter   \(nsCol) ns/op   \(totalStr)")
}

func printHeader(_ title: String) {
    let bar = String(repeating: "─", count: 75)
    print("\n\(bar)")
    print("  \(title)")
    print(bar)
}

private func formatCount(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return "\(n / 1_000_000)M"
    case 1_000...:     return "\(n / 1_000)K"
    default:           return "\(n)"
    }
}

// MARK: - Black-hole sink (prevents the optimizer from eliminating side-effect-free reads)

/// A global accumulator that the optimizer cannot see through.
/// Add values into it to prevent pure reads from being elided.
nonisolated(unsafe) var blackhole: Int = 0

private extension String {
    func leftPad(toLength length: Int) -> String {
        let pad = max(0, length - count)
        return String(repeating: " ", count: pad) + self
    }
}
