import Testing
import ConcurrencyExtras
@testable import SwiftModel

// `node.ifAlive` runs work the model does not own (a view's onDisappear, a callback, a
// view's .refreshable) and drops, without a report, the writes that land on the model
// after it was removed. The removal is driven from inside the body here, so the race
// it guards against (a removal on another thread between a check and a write) is
// covered deterministically.

@Model private struct AliveHost {
    var child: AliveChild? = AliveChild()
    var other: AliveChild? = AliveChild()
}

@Model private struct AliveChild {
    var name = "child"
}

/// Calls `body` from a synchronous context, so `ifAlive` in it resolves to the synchronous
/// overload (an async context picks the async one even for a synchronous closure).
private func inSyncContext<R>(_ body: () -> R) -> R { body() }

private func isRemovedWrite(_ issue: Issue) -> Bool {
    issue.description.contains("Modifying a removed `AliveChild` model")
}

@Suite(.modelTesting(exhaustivity: .off))
struct IfAliveTests {
    @Test func runsAndReturnsWhileAlive() async {
        let host = AliveHost().withAnchor()
        let child = host.child!

        let result = inSyncContext {
            child.node.ifAlive {
                child.name = "updated"
                return 1
            }
        }

        #expect(result == 1)
        #expect(child.name == "updated")
    }

    @Test func skipsWhenAlreadyRemoved() async {
        let host = AliveHost().withAnchor()
        let child = host.child!
        host.child = nil

        let ran = LockIsolated(false)
        let result: Int? = inSyncContext {
            child.node.ifAlive {
                ran.setValue(true)
                return 1
            }
        }

        #expect(result == nil)
        #expect(!ran.value)
    }

    @Test func writeAfterRemovalDuringBodyIsSilent() async {
        let host = AliveHost().withAnchor()
        let child = host.child!

        let result = inSyncContext {
            child.node.ifAlive {
                host.child = nil   // the removal racing the body
                child.name = "late"
                return 1
            }
        }

        #expect(result == nil)
        #expect(child.name == "child")
    }

    @Test func writeToAnotherRemovedModelWhileAliveIsReported() async {
        let host = AliveHost().withAnchor()
        let child = host.child!

        withKnownIssue {
            // The scope's model is alive, so this is a removed child written by live work.
            inSyncContext {
                host.node.ifAlive {
                    host.child = nil
                    child.name = "late"
                }
            }
        } matching: { isRemovedWrite($0) }
    }

    @Test func nestedScopesEachCheckTheirOwnModel() async {
        let host = AliveHost().withAnchor()
        let child = host.child!
        let other = host.other!

        let outer: Int? = inSyncContext {
            host.node.ifAlive {
                let inner: Int? = child.node.ifAlive {
                    host.child = nil
                    child.name = "late"
                    return 1
                }
                #expect(inner == nil)
                return 1
            }
        }
        #expect(outer == 1)

        // An outer scope still covers its model inside an inner scope of another model.
        let silenced: Int?? = inSyncContext {
            other.node.ifAlive {
                host.node.ifAlive {
                    host.other = nil
                    other.name = "late"
                    return 1
                }
            }
        }
        #expect(silenced == nil)
        #expect(other.name == "child")
    }

    @Test func taskOutlivingTheScopeIsReported() async {
        let host = AliveHost().withAnchor()
        let child = host.child!
        let (gate, open) = AsyncStream.makeStream(of: Void.self)

        // The `Task` binds the known-issue scope when it is created, so create it inside.
        await withKnownIssue {
            let task = inSyncContext {
                child.node.ifAlive {
                    Task {
                        for await _ in gate { break }
                        child.name = "late"
                    }
                }
            }
            host.child = nil
            open.yield()
            await task?.value
        } matching: { isRemovedWrite($0) }
    }

    @Test func unanchoredModelIsReported() {
        let ran = LockIsolated(false)
        withKnownIssue {
            inSyncContext { AliveChild().node.ifAlive { ran.setValue(true) } }
        } matching: { $0.description.contains("unanchored") }
        #expect(!ran.value)
    }

    @Test func asyncRunsAndReturnsWhileAlive() async {
        let host = AliveHost().withAnchor()
        let child = host.child!

        let result = await child.node.ifAlive {
            await Task.yield()
            child.name = "updated"
            return 1
        }

        #expect(result == 1)
        #expect(child.name == "updated")
    }

    @Test func asyncRemovalCancelsBodyAndSilencesWrites() async {
        let host = AliveHost().withAnchor()
        let child = host.child!
        let (started, didStart) = AsyncStream.makeStream(of: Void.self)
        let wasCancelled = LockIsolated(false)

        async let result: Int? = child.node.ifAlive {
            didStart.yield()
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            wasCancelled.setValue(Task.isCancelled)
            child.name = "late"
            return 1
        }
        for await _ in started { break }
        host.child = nil

        #expect(await result == nil)
        #expect(wasCancelled.value)
        #expect(child.name == "child")
    }

    @Test func asyncThrowingRemovalReturnsNil() async throws {
        let host = AliveHost().withAnchor()
        let child = host.child!
        let (started, didStart) = AsyncStream.makeStream(of: Void.self)

        async let result: Int? = child.node.ifAlive {
            didStart.yield()
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return 1
        }
        for await _ in started { break }
        host.child = nil

        #expect(try await result == nil)
    }

    @Test func asyncThrowingCallerCancellationIsRethrown() async {
        let host = AliveHost().withAnchor()
        let child = host.child!
        let (started, didStart) = AsyncStream.makeStream(of: Void.self)

        let task = Task {
            try await child.node.ifAlive {
                didStart.yield()
                try await Task.sleep(nanoseconds: 60_000_000_000)
                return 1
            }
        }
        for await _ in started { break }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(host.child != nil)
    }

    @Test func asyncBodyErrorIsRethrown() async {
        struct Failure: Error {}
        let host = AliveHost().withAnchor()
        let child = host.child!

        await #expect(throws: Failure.self) {
            try await child.node.ifAlive { () async throws -> Int in throw Failure() }
        }
    }

    @Test func asyncSkipsWhenAlreadyRemoved() async {
        let host = AliveHost().withAnchor()
        let child = host.child!
        host.child = nil

        let ran = LockIsolated(false)
        let result: Int? = await child.node.ifAlive {
            ran.setValue(true)
            return 1
        }

        #expect(result == nil)
        #expect(!ran.value)
    }
}
