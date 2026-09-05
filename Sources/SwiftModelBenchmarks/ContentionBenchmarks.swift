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
