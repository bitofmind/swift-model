import Testing
import Foundation
import ConcurrencyExtras
@testable import SwiftModel

/// A model task that loops without ever waiting for anything never lets the model go
/// quiet, so `settle()` and an unmet `expect` used to run to the trait's absolute
/// ceiling. The common case is a timer loop on a clock whose sleep returns at once (an
/// `ImmediateClock`); here each pass awaits a plain `Task {}`, as such a clock's sleep
/// does through an async operator. The drive counts each model task's resumes per call
/// site and fails the wait once one site passes the runaway bound, naming the task.
@Suite("drive runaway-task evidence")
struct RunawayTaskTests {

    @Test func busyLoopFailsSettleNamingTheTask() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        await TestAccessOverrides.$settleRunawayFireBound.withValue(200) {
            await withModelTesting(.off) {
                let model = BusyLoopModel().withAnchor()
                await withKnownIssue {
                    await guarded { await settle() }
                } matching: { issue in
                    let text = String(describing: issue)
                    return text.contains("runaway task") && text.contains("RunawayTaskTests.swift")
                }
                model.stop.setValue(true)
                await settle()
            }
        }
    }

    @Test func busyLoopFailsUnmetExpectNamingTheTask() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        await TestAccessOverrides.$settleRunawayFireBound.withValue(200) {
            await withModelTesting(.off) {
                let model = BusyLoopModel().withAnchor()
                await withKnownIssue {
                    await guarded { await expect(model.value == 1) }
                } matching: { issue in
                    let text = String(describing: issue)
                    return text.contains("runaway task") || text.contains("Expectation not met")
                }
                model.stop.setValue(true)
                await settle()
            }
        }
    }

    /// A long but finite loop stays far below the default bound and settles normally.
    @Test func finiteLoopSettles() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        await withModelTesting(.off) {
            let model = FiniteLoopModel().withAnchor()
            await settle()
            #expect(model.passes == 2_000)
        }
    }

    /// Bounds the meta-test on regression only: if the runaway verdict never lands, the
    /// wait is cancelled (silently), so `withKnownIssue` fails fast with "no known issue
    /// recorded" instead of parking on the drive's termination ceiling.
    private func guarded(_ wait: @escaping @Sendable () async -> Void) async {
        let waitTask = Task { await wait() }
        let guardSeconds = 20 * ModelTestingTraitOptions.timeoutScale
        let guardTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(guardSeconds * 1_000_000_000))
            waitTask.cancel()
        }
        await waitTask.value
        guardTask.cancel()
    }
}

@Model private struct BusyLoopModel {
    var value = 0
    let stop = LockIsolated(false)

    func onActivate() {
        node.task {
            while !stop.value, !Task.isCancelled {
                _ = await Task { 1 }.value
            }
        }
    }
}

@Model private struct FiniteLoopModel {
    var passes = 0

    func onActivate() {
        node.task {
            var n = 0
            for _ in 0..<2_000 {
                _ = await Task { 1 }.value
                n += 1
            }
            passes = n
        }
    }
}
