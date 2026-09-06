import Foundation
import SwiftModel
import IdentifiedCollections
import Synchronization
#if canImport(os)
import os
#endif

// Contention / scaling probe. Every row reports ns per op *per thread* at
// 1/2/4/8 threads, so a flat row is perfect scaling and growth is serialization
// (or shared-cache-line traffic). Baseline on an M1 Max (2026-09-05) and the
// profile attributions behind each row are in the PR that added this file.
//
//   swift run -c release SwiftModelBenchmarks --contention
//   swift run -c release SwiftModelBenchmarks --profile "<row name>" <threads>
//
// `--profile` loops one row for ~8 s so you can attach `sample <pid> 3` or
// Instruments. Both modes run OFF the main thread so the MainActor can drain
// SwiftModel's main-registrar notification queue, as it would in a real app —
// with the main thread blocked, off-main writes to a model that has ever been
// read on main grow that queue without bound and the numbers are meaningless.

private func perThreadNs(threads: Int, perThread: Int, _ body: @Sendable (Int) -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    DispatchQueue.concurrentPerform(iterations: threads) { i in body(i) }
    let elapsed = DispatchTime.now().uptimeNanoseconds &- start
    return Double(elapsed) / Double(perThread)
}

final class Box: @unchecked Sendable { var v = 0 }

/// name → (perThread, body). Body loops `perThread` times.
nonisolated(unsafe) var scenarios: [(name: String, perThread: Int, body: @Sendable (Int) -> Void)] = []
nonisolated(unsafe) var keepAlive: [Any] = []

private func add(_ name: String, perThread: Int = 200_000, _ body: @escaping @Sendable (Int) -> Void) {
    scenarios.append((name, perThread, body))
}

@available(macOS 15.0, *)
func buildScenarios() {
    // C1 lock primitives
    let l = NSRecursiveLock(); let b = Box()
    add("c1 NSRecursiveLock shared") { _ in for _ in 0..<200_000 { l.lock(); b.v &+= 1; l.unlock() } }
    let l2 = NSLock()
    add("c1 NSLock shared") { _ in for _ in 0..<200_000 { l2.lock(); b.v &+= 1; l2.unlock() } }
#if canImport(os)
    let l3 = OSAllocatedUnfairLock(initialState: 0)
    add("c1 OSAllocatedUnfairLock shared") { _ in for _ in 0..<200_000 { l3.withLock { $0 &+= 1 } } }
#endif
    let l4 = Mutex(0)
    add("c1 Synchronization.Mutex shared") { _ in for _ in 0..<200_000 { l4.withLock { $0 &+= 1 } } }
    let locks = (0..<8).map { _ in NSRecursiveLock() }
    let boxes = (0..<8).map { _ in Box() }
    add("c1 NSRecursiveLock distinct per thread") { i in let l = locks[i]; let b = boxes[i]; for _ in 0..<200_000 { l.lock(); b.v &+= 1; l.unlock() } }

    // C2 shared refcount traffic: copy a shared class ref into an array slot (forces retain/release)
    let shared = Box()
    let sharedArr = (0..<8).map { _ in Box() }
    add("c2 retain/release ONE shared object") { i in
        var slot: [Box] = [shared]
        for _ in 0..<200_000 { slot[0] = shared; blackhole &+= slot[0].v }
    }
    add("c2 retain/release distinct objects") { i in
        let mine = sharedArr[i]
        var slot: [Box] = [mine]
        for _ in 0..<200_000 { slot[0] = mine; blackhole &+= slot[0].v }
    }

    // C3 reads
    var distinct: [BenchCounter] = []
    for _ in 0..<8 { let (m, a) = BenchCounter().returningAnchor(); distinct.append(m); keepAlive.append(a) }
    let dm = distinct
    add("c3 tracked read distinct trees") { i in let m = dm[i]; var s = 0; for _ in 0..<200_000 { s &+= m.count }; blackhole &+= s }
    add("c3 untracked read distinct trees") { i in let m = dm[i]; var s = 0; withUntrackedModelReads { for _ in 0..<200_000 { s &+= m.count } }; blackhole &+= s }
    let (list, la) = BenchList(items: IdentifiedArray(uniqueElements: (0..<8).map { BenchItem(id: $0) })).returningAnchor()
    keepAlive.append(la)
    let children = (0..<8).map { list.items[id: $0]! }
    add("c3 tracked read children of ONE tree") { i in let m = children[i]; var s = 0; for _ in 0..<200_000 { s &+= m.value }; blackhole &+= s }
    add("c3 untracked read children of ONE tree") { i in let m = children[i]; var s = 0; withUntrackedModelReads { for _ in 0..<200_000 { s &+= m.value } }; blackhole &+= s }
    let one = dm[0]
    add("c3 tracked read ONE shared model") { _ in var s = 0; for _ in 0..<200_000 { s &+= one.count }; blackhole &+= s }
    add("c3 untracked read ONE shared model") { _ in var s = 0; withUntrackedModelReads { for _ in 0..<200_000 { s &+= one.count } }; blackhole &+= s }

    // C4 writes
    var wdistinct: [BenchCounter] = []
    for _ in 0..<8 { let (m, a) = BenchCounter().returningAnchor(); wdistinct.append(m); keepAlive.append(a) }
    let wdm = wdistinct
    add("c4 write distinct trees", perThread: 50_000) { i in let m = wdm[i]; for _ in 0..<50_000 { m.count &+= 1 } }
    let (wlist, wla) = BenchList(items: IdentifiedArray(uniqueElements: (0..<8).map { BenchItem(id: $0) })).returningAnchor()
    keepAlive.append(wla)
    let wchildren = (0..<8).map { wlist.items[id: $0]! }
    add("c4 write children of ONE tree", perThread: 3_000) { i in let m = wchildren[i]; for _ in 0..<3_000 { m.value &+= 1 } }
    let wone = wdm[0]
    add("c4 write ONE shared model", perThread: 3_000) { _ in for _ in 0..<3_000 { wone.count &+= 1 } }

    // C4m: the same writes against models that have a MAIN registrar — they were
    // tracked-read on the main thread once, as any model a SwiftUI view has rendered
    // has been. From then on every off-main write must hand its main-registrar
    // willSet/didSet to `MainCallQueue` for delivery on the main actor (which is
    // draining here). The rows above never take that path: nothing in this file runs
    // on main, so those models have no main registrar at all.
    let (tlist, tla) = BenchList(items: IdentifiedArray(uniqueElements: (0..<8).map { BenchItem(id: $0) })).returningAnchor()
    keepAlive.append(tla)
    let tchildren = (0..<8).map { tlist.items[id: $0]! }
    var tdistinct: [BenchCounter] = []
    for _ in 0..<8 { let (m, a) = BenchCounter().returningAnchor(); tdistinct.append(m); keepAlive.append(a) }
    let tdm = tdistinct
    DispatchQueue.main.sync {
        withObservationTracking {
            for c in tchildren { blackhole &+= c.value }
            for m in tdm { blackhole &+= m.count }
        } onChange: {}
    }
    add("c4m write children of ONE tree, main-tracked", perThread: 3_000) { i in let m = tchildren[i]; for _ in 0..<3_000 { m.value &+= 1 } }
    add("c4m write ONE shared model, main-tracked", perThread: 3_000) { _ in let m = tdm[0]; for _ in 0..<3_000 { m.count &+= 1 } }
    add("c4m write distinct trees, main-tracked", perThread: 3_000) { i in let m = tdm[i]; for _ in 0..<3_000 { m.count &+= 1 } }
    add("c4m burst 100k writes ONE model, main-tracked", perThread: 100_000) { _ in let m = tdm[1]; for _ in 0..<100_000 { m.count &+= 1 } }

    // C5 mixed
    let (mlist, mla) = BenchList(items: IdentifiedArray(uniqueElements: (0..<8).map { BenchItem(id: $0) })).returningAnchor()
    keepAlive.append(mla)
    let mchildren = (0..<8).map { mlist.items[id: $0]! }
    add("c5 1 writer + N-1 tracked readers ONE tree", perThread: 20_000) { i in
        let m = mchildren[i]
        if i == 0 { for _ in 0..<20_000 { m.value &+= 1 } }
        else { var s = 0; for _ in 0..<20_000 { s &+= m.value }; blackhole &+= s }
    }
    add("c5 1 writer + N-1 tracked readers distinct", perThread: 20_000) { i in
        let m = wdm[i]
        if i == 0 { for _ in 0..<20_000 { m.count &+= 1 } }
        else { var s = 0; for _ in 0..<20_000 { s &+= m.count }; blackhole &+= s }
    }
}

@available(macOS 15.0, *)
func benchContention() {
    buildScenarios()
    printHeader("Scaling: ns per op per thread at 1/2/4/8 threads (flat = perfect scaling)")
    for sc in scenarios {
        sc.body(0)
        var cols: [String] = []
        for n in [1, 2, 4, 8] {
            let ns = perThreadNs(threads: n, perThread: sc.perThread, sc.body)
            cols.append(String(format: "%dT:%8.0f", n, ns))
        }
        print("  \(sc.name.padding(toLength: 46, withPad: " ", startingAt: 0)) \(cols.joined(separator: "  "))")
        fflush(nil)  // not `stdout`: Swift 6 rejects that global on Linux as non-Sendable
    }

    printHeader("C6. Actor comparison — ns per `await actor.count` per task (1/2/4/8 tasks)")
    actor Counter { var count = 0; func inc() { count &+= 1 } }
    let shared = Counter()
    let distinct = (0..<8).map { _ in Counter() }
    func run(_ name: String, _ pick: @Sendable @escaping (Int) -> Counter) {
        var cols: [String] = []
        for n in [1, 2, 4, 8] {
            let sem = DispatchSemaphore(value: 0)
            let start = DispatchTime.now().uptimeNanoseconds
            Task.detached {
                await withTaskGroup(of: Void.self) { g in
                    for i in 0..<n {
                        g.addTask {
                            let a = pick(i); var s = 0
                            for _ in 0..<200_000 { s &+= await a.count }
                            blackhole &+= s
                        }
                    }
                }
                sem.signal()
            }
            sem.wait()
            let ns = Double(DispatchTime.now().uptimeNanoseconds &- start) / 200_000
            cols.append(String(format: "%dT:%8.0f", n, ns))
        }
        print("  \(name.padding(toLength: 46, withPad: " ", startingAt: 0)) \(cols.joined(separator: "  "))")
    }
    run("actor read, distinct actors") { distinct[$0] }
    run("actor read, ONE shared actor") { _ in shared }
}

@available(macOS 15.0, *)
func profileScenario(_ name: String, threads: Int) {
    buildScenarios()
    guard let sc = scenarios.first(where: { $0.name == name }) else { print("unknown scenario \(name)"); return }
    print("profiling \(name) at \(threads) threads, pid \(ProcessInfo.processInfo.processIdentifier)")
    fflush(nil)
    let start = DispatchTime.now().uptimeNanoseconds
    var reps = 0
    while DispatchTime.now().uptimeNanoseconds &- start < 8_000_000_000 {
        DispatchQueue.concurrentPerform(iterations: threads) { i in sc.body(i) }
        reps += 1
    }
    print("done \(reps) reps")
}

/// Main-thread stall probe (snapshot-reads spike). The MAIN thread performs tracked reads
/// of one root scalar in a tight loop for `seconds`, timing every read, while a background
/// thread runs `node.transaction` bodies on the SAME tree that each hold the hierarchy lock
/// for a few ms (a 3 ms spin, or an append+remove reconcile on a 500-item collection).
/// Reports the reader's p50 / p99 / p99.9 / max latency and how many reads exceeded 1 ms.
/// With the lock-taking read path the max tracks the transaction duration; with snapshot
/// reads it should track the no-writer noise floor.
///
/// Runs ON the main thread deliberately (the models get a main registrar, as any
/// SwiftUI-rendered model has); the run loop is pumped between 256-read batches so the
/// main-registrar notification queue that off-main writes feed keeps draining. The pump is
/// outside the timed region.
///
///   swift run -c release SwiftModelBenchmarks --stall
@available(macOS 15.0, *)
func benchStall(seconds: Double = 2.0) {
    printHeader("Main-thread stall: tracked reads on MAIN during background ~ms transactions on the same tree")
    var items: IdentifiedArrayOf<BenchItem> = []
    for i in 0..<500 { items.append(BenchItem(id: i)) }
    let (list, anchor) = BenchList(items: items).returningAnchor()
    keepAlive.append(anchor)
    let child0 = list.items[id: 0]!
    blackhole &+= list.selectedID ?? 0  // main-thread read → main registrar, like a rendered view
    blackhole &+= child0.value

    @inline(__always) @Sendable func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    @Sendable func spin(_ ns: UInt64) { let t = now(); while now() &- t < ns {} }

    let variants: [(name: String, read: @Sendable () -> Int, writer: (@Sendable () -> Void)?)] = [
        ("no writer (noise floor), read root scalar", { list.selectedID ?? 0 }, nil),
        ("writer: transaction spinning 3 ms, read root scalar", { list.selectedID ?? 0 }, {
            list.node.transaction { list.selectedID = 1; spin(3_000_000) }
        }),
        ("writer: transaction spinning 3 ms, read child value", { child0.value }, {
            list.node.transaction { list.selectedID = 1; spin(3_000_000) }
        }),
        ("writer: append+remove on 500 items, read root scalar", { list.selectedID ?? 0 }, {
            list.node.transaction { list.items.append(BenchItem(id: 100_000)); list.items.remove(id: 100_000) }
        }),
        ("writer: append+remove on 500 items, read child value", { child0.value }, {
            list.node.transaction { list.items.append(BenchItem(id: 100_000)); list.items.remove(id: 100_000) }
        }),
    ]

    print("  " + "variant".padding(toLength: 54, withPad: " ", startingAt: 0) + "      reads     p50      p99    p99.9      max   >1ms   writer txns (mean ms)")
    for v in variants {
        let stop = Atomic<Bool>(false)
        let done = DispatchSemaphore(value: 0)
        let txnStats = Mutex<(count: Int, ns: UInt64)>((0, 0))
        if let writer = v.writer {
            let t = Thread {
                while !stop.load(ordering: .relaxed) {
                    let t0 = now()
                    writer()
                    let dt = now() &- t0
                    txnStats.withLock { $0.count += 1; $0.ns &+= dt }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                done.signal()
            }
            t.qualityOfService = .userInitiated
            t.start()
            Thread.sleep(forTimeInterval: 0.01)
        }
        var lat: [UInt64] = []
        lat.reserveCapacity(8_000_000)
        let end = now() &+ UInt64(seconds * 1e9)
        let read = v.read
        while now() < end {
            for _ in 0..<256 {
                let t0 = now()
                blackhole &+= read()
                lat.append(now() &- t0)
            }
            RunLoop.main.run(mode: .default, before: Date())
        }
        stop.store(true, ordering: .relaxed)
        if v.writer != nil { done.wait() }
        lat.sort()
        let n = lat.count
        func pct(_ p: Double) -> Double { Double(lat[min(n - 1, Int(Double(n) * p))]) }
        let over1ms = lat.reversed().prefix { $0 > 1_000_000 }.count
        let ts = txnStats.withLock { $0 }
        let txnCol = ts.count > 0 ? String(format: "%5d (%.2f)", ts.count, Double(ts.ns) / Double(ts.count) / 1e6) : "    -"
        print(String(format: "  %@ %10d %7.0f %8.0f %8.0f %8.0f %6d   %@",
                     v.name.padding(toLength: 54, withPad: " ", startingAt: 0) as NSString,
                     n, pct(0.5), pct(0.99), pct(0.999), Double(lat[n - 1]), over1ms, txnCol as NSString))
        fflush(nil)
    }
    print("  (latencies in ns; max/p99.9 are the numbers that matter — a lock-taking read's max tracks the transaction length)")
}

/// Off-main write burst against ONE model that has a main registrar, in Release:
/// the write-phase cost per write and how long main takes to drain afterwards,
/// with main draining concurrently and with main blocked for the whole write
/// phase (a busy UI thread — layout, a long body, a synchronous load).
///
///   swift run -c release SwiftModelBenchmarks --burst
@available(macOS 15.0, *)
func benchBurst() {
    let writes = 100_000
    printHeader("Burst: \(writes / 1000)k off-main writes to ONE main-tracked model (3 passes each)")
    let (m, a) = BenchCounter().returningAnchor()
    keepAlive.append(a)
    DispatchQueue.main.sync {
        withObservationTracking { blackhole &+= m.count } onChange: {}
    }
    for (label, blockMain) in [("main draining", false), ("main blocked during writes", true)] {
        for _ in 0..<3 {
            let fired = Mutex<(UInt64, Bool)?>(nil)
            DispatchQueue.main.sync {
                withObservationTracking { blackhole &+= m.count } onChange: {
                    fired.withLock { $0 = (DispatchTime.now().uptimeNanoseconds, Thread.isMainThread) }
                }
            }
            let release = DispatchSemaphore(value: 0)
            if blockMain {
                DispatchQueue.main.async { release.wait() }
                Thread.sleep(forTimeInterval: 0.02)  // not usleep: absent on Android
            }
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<writes { m.count &+= 1 }
            let writeNs = DispatchTime.now().uptimeNanoseconds &- t0
            if blockMain { release.signal() }
            // Main-queue FIFO: this lands behind the drain job that the first write
            // enqueued, which delivers everything queued so far in one batch.
            let drained = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { drained.signal() }
            drained.wait()
            let totalNs = DispatchTime.now().uptimeNanoseconds &- t0
            // The tracking registered above is on the MAIN registrar, so its onChange
            // proves the bridge is engaged (and ran on main); it precedes the marker.
            let first = fired.withLock { $0 }.map { String(format: "%.1f ms on %@", Double($0.0 &- t0) / 1e6, $0.1 ? "main" : "NOT main") } ?? "never"
            print(String(format: "  %-28@  writes %7.1f ms (%6.0f ns/write)   drained at %7.1f ms   first main delivery %@",
                         label as NSString, Double(writeNs) / 1e6, Double(writeNs) / Double(writes), Double(totalNs) / 1e6, first as NSString))
        }
    }
}
