#if canImport(Dispatch)
import Foundation
import Testing
import ConcurrencyExtras
@testable import SwiftModel

/// Coverage for the opt-in expect trace (`SWIFT_MODEL_EXPECT_TRACE=1`): an
/// `expect` that only passes at the executor drive's fixpoint re-check, rather
/// than on the reactive wake of the write that made it true, is reported with
/// the reason its last failing evaluation failed.
///
/// The fixpoint pass is forced with a predicate that turns true on its own
/// (on its second evaluation) while the model is idle, so no reactive wake
/// can see it change.
@Suite("expect fixpoint trace")
struct ExpectFixpointTraceTests {

    @Test func untrackedPassIsReportedAsFixpointPass() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        let lines = LockIsolated<[String]>([])
        await TestAccessOverrides.$expectGraceNanoseconds.withValue(50_000_000) {
            await TestAccessOverrides.$expectTraceSink.withValue({ line in lines.withValue { $0.append(line) } }) {
                await withModelTesting(.off) {
                    let model = TraceModel().withAnchor()
                    await settle()
                    // False on the initial evaluation, true on the next one. The
                    // model is idle, so the next evaluation is the fixpoint re-check.
                    let evaluations = LockIsolated(0)
                    await expect {
                        model.count == 0 && evaluations.withValue { $0 += 1; return $0 >= 2 }
                    }
                }
            }
        }
        let traced = lines.value
        #expect(traced.count == 1)
        #expect(traced.first?.contains("ExpectFixpointTraceTests.swift") == true)
        #expect(traced.first?.contains("fixpoint re-check") == true)
        #expect(traced.first?.contains("predicate false") == true)
    }

    @Test func reactivePassIsNotReported() async {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *) else { return }
        let lines = LockIsolated<[String]>([])
        await TestAccessOverrides.$expectGraceNanoseconds.withValue(50_000_000) {
            await TestAccessOverrides.$expectTraceSink.withValue({ line in lines.withValue { $0.append(line) } }) {
                await withModelTesting(.off) {
                    let model = TraceModel().withAnchor()
                    model.bumpLater()
                    await expect { model.count == 1 }
                    await expect { model.count == 1 }   // passes on the initial evaluation
                }
            }
        }
        #expect(lines.value.isEmpty)
    }
}

@Model private struct TraceModel {
    var count = 0

    func bumpLater() {
        node.task {
            try await Task.sleep(nanoseconds: 10_000_000)
            count += 1
        } catch: { _ in }
    }
}
#endif
