import Testing
@testable import SwiftModel

protocol ExistentialHook: Model {
    var dim: Double { get }
    func bump()
}

@Model private struct ExistentialHost {
    var hook: (any ExistentialHook)? = nil
    var dimValue: Double { hook?.dim ?? 0 }
}

@Model private struct HookA: ExistentialHook {
    var dim: Double = 1
    var activated = false
    func bump() { dim += 1 }
    func onActivate() { activated = true }
}

@Model private struct HookB: ExistentialHook {
    var dim: Double = 10
    func bump() { dim += 10 }
}

@Suite(.modelTesting(exhaustivity: .off))
struct ExistentialChildModelTests {
    @Test func assignedExistentialChildIsAnchoredAndActivated() async throws {
        let host = ExistentialHost().withAnchor()
        host.hook = HookA()
        let a = try #require(host.hook as? HookA)
        #expect(a.lifetime == .active)
        await expect(a.activated)
        host.hook?.bump()
        await expect(host.dimValue == 2)
    }

    @Test func initialExistentialChildIsAnchored() async throws {
        let host = ExistentialHost(hook: HookA()).withAnchor()
        let a = try #require(host.hook as? HookA)
        #expect(a.lifetime == .active)
        await expect(a.activated)
    }

    @Test func replacingAndClearingRemovesThePreviousChild() async throws {
        let host = ExistentialHost(hook: HookA()).withAnchor()
        let a = try #require(host.hook as? HookA)
        host.hook = HookB()
        #expect(a.lifetime == .destructed)
        let b = try #require(host.hook as? HookB)
        #expect(b.lifetime == .active)
        b.bump()
        await expect(host.dimValue == 20)
        host.hook = nil
        #expect(b.lifetime == .destructed)
    }
}

private enum HookEvent: Sendable, Equatable { case ping(Int) }

protocol RequiredHook: Model {
    var count: Int { get }
    func ping()
}

@Model private struct PingHook: RequiredHook {
    var count = 0
    func ping() {
        count += 1
        node.send(HookEvent.ping(count))
    }
    func onActivate() {
        node.task {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch: { _ in }
    }
}

@Model private struct RequiredHost {
    var hook: any RequiredHook
    var lastPing = 0
    func onActivate() {
        node.forEach(node.event(ofType: HookEvent.self)) { event in
            if case let .ping(n) = event { lastPing = n }
        }
    }
}

@Model private struct ValueExistentialHost {
    var label: any CustomStringConvertible = "a"
    var optionalLabel: (any CustomStringConvertible)? = nil
}

@Suite(.modelTesting)
struct ExistentialChildModelExhaustiveTests {
    @Test func childWritesAndEventsAreTrackedExhaustively() async throws {
        let host = RequiredHost(hook: PingHook()).withAnchor()
        await settle()
        host.hook.ping()
        let hook = try #require(host.hook as? PingHook)
        await expect {
            hook.count == 1
            host.lastPing == 1
            hook.didSend(HookEvent.ping(1))
        }
    }

    @Test func replacingANonOptionalExistentialChildCancelsItsTasks() async throws {
        let host = RequiredHost(hook: PingHook()).withAnchor()
        await settle()
        let old = try #require(host.hook as? PingHook)
        host.hook = PingHook()
        #expect(old.lifetime == .destructed)
        let new = try #require(host.hook as? PingHook)
        #expect(new.lifetime == .active)
        await expect(host.hook.count == 0)
    }

    @Test func nonModelExistentialsStayPlainValues() async {
        let host = ValueExistentialHost().withAnchor()
        host.label = 42
        host.optionalLabel = "b"
        await expect {
            host.label.description == "42"
            host.optionalLabel?.description == "b"
        }
    }
}

@Suite(.modelTesting(exhaustivity: .off))
struct ExistentialChildModelCopyTests {
    @Test func frozenCopyFreezesTheExistentialChild() async throws {
        let host = ExistentialHost(hook: HookA()).withAnchor()
        let copy = host.frozenCopy
        let child = try #require(copy.hook as? HookA)
        #expect(child.lifetime == .frozenCopy)
        let live = try #require(host.hook as? HookA)
        #expect(live.lifetime == .active)
    }

    @Test func sameIDAssignmentContinuesTheLiveChild() async throws {
        let host = ExistentialHost(hook: HookA()).withAnchor()
        let a = try #require(host.hook as? HookA)
        host.hook = a
        #expect(a.lifetime == .active)
        a.bump()
        await expect(host.dimValue == 2)
    }

    @Test func childIsInTheHierarchy() async throws {
        let host = ExistentialHost(hook: HookA()).withAnchor()
        let descendants = host.node.reduceHierarchy(for: [.descendants], transform: { "\(type(of: $0))" }, into: [String]()) { $0.append($1) }
        #expect(descendants == ["HookA"])
    }
}

@Model private struct UndoableExistentialHost {
    var label: any CustomStringConvertible = "a"
    var hook: (any ExistentialHook)? = nil
    func onActivate() { node.trackUndo() }
}

@Suite(.modelTesting(exhaustivity: .off))
struct ExistentialChildModelUndoTests {
    @Test func undoRestoresANonModelExistential() async {
        let stack = ModelUndoStack()
        let host = UndoableExistentialHost().withAnchor { $0.undoSystem.backend = stack }
        host.label = 42
        await expect(host.label.description == "42")
        #expect(stack.canUndo)
        stack.undo()
        await expect(host.label.description == "a")
    }

    @Test func undoRestoresAnExistentialChild() async throws {
        let stack = ModelUndoStack()
        let host = UndoableExistentialHost(hook: HookA()).withAnchor { $0.undoSystem.backend = stack }
        host.hook = HookB()
        await expect(host.dimValue == 10)
        #expect(stack.canUndo)
        stack.undo()
        await expect(host.hook is HookA)
        let restored = try #require(host.hook as? HookA)
        #expect(restored.lifetime == .active)
        restored.bump()
        await expect(host.dimValue == 2)
    }
}

private extension UndoableExistentialHost {
    var dimValue: Double { hook?.dim ?? 0 }
}

@ModelContainer private enum HookSlot {
    case none
    case hook(any ExistentialHook)
    case labelled(String, hook: any ExistentialHook)
}

@ModelContainer private struct HookPair {
    var first: any ExistentialHook
    var second: (any ExistentialHook)?
}

@Model private struct ContainerExistentialHost {
    var slot: HookSlot = .none
    var pair: HookPair? = nil
}

@Model private struct CollectionExistentialHost {
    var hooks: [any ExistentialHook] = []
}

@Suite(.modelTesting(exhaustivity: .off))
struct ExistentialChildContainerTests {
    @Test func enumPayloadIsAnchoredAndReplaced() async throws {
        let host = ContainerExistentialHost(slot: .hook(HookA())).withAnchor()
        guard case let .hook(first) = host.slot, let a = first as? HookA else { Issue.record("no hook"); return }
        #expect(a.lifetime == .active)
        await expect(a.activated)

        host.slot = .labelled("b", hook: HookB())
        #expect(a.lifetime == .destructed)
        guard case let .labelled(_, hook: second) = host.slot, let b = second as? HookB else { Issue.record("no hook"); return }
        #expect(b.lifetime == .active)
        b.bump()
        await expect(b.dim == 20)

        host.slot = .none
        #expect(b.lifetime == .destructed)
    }

    @Test func modelContainerStructFieldsAreAnchored() async throws {
        let host = ContainerExistentialHost().withAnchor()
        host.pair = HookPair(first: HookA(), second: HookB())
        let pair = try #require(host.pair)
        let a = try #require(pair.first as? HookA)
        let b = try #require(pair.second as? HookB)
        #expect(a.lifetime == .active && b.lifetime == .active)
        await expect(a.activated)

        host.pair?.second = nil
        #expect(b.lifetime == .destructed)
        #expect(a.lifetime == .active)

        host.pair = nil
        #expect(a.lifetime == .destructed)
    }

    @Test func aCollectionOfExistentialModelsIsReported() async {
        withKnownIssue {
            _ = CollectionExistentialHost(hooks: [HookA()]).withAnchor()
        } matching: { $0.description.contains("collections of existential models are not supported") }
    }
}
