import Testing
@testable import SwiftModel

protocol CollectionHook: Model {
    var count: Int { get nonmutating set }
    var activations: Int { get }
}

@Model private struct CountHook: CollectionHook {
    var count = 0
    var activations = 0
    func onActivate() {
        activations += 1
        node.task {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch: { _ in }
    }
}

@Model private struct OtherHook: CollectionHook {
    var count = 100
    var activations = 0
    func onActivate() { activations += 1 }
}

private enum HookEvent: Sendable, Equatable { case tapped(Int) }

@Model private struct EventHook: CollectionHook {
    var count = 0
    var activations = 0
    func tap() { node.send(HookEvent.tapped(count)) }
}

@Model private struct ArrayHost {
    var hooks: [any CollectionHook] = []
    var optionalHooks: [(any CollectionHook)?] = []
    var byName: [String: any CollectionHook] = [:]
    var lastTap = -1
    var total: Int { hooks.reduce(0) { $0 + $1.count } }
    func onActivate() {
        node.forEach(node.event(ofType: HookEvent.self)) { event in
            if case let .tapped(n) = event { lastTap = n }
        }
    }
}

@Model private struct InnerModel {
    var activated = false
    func onActivate() { activated = true }
}

@Model private struct NestingHook: CollectionHook {
    var count = 0
    var activations = 0
    var inner = InnerModel()
    func onActivate() { activations += 1 }
}

@Model private struct OptionalArrayHost {
    var hooks: [any CollectionHook]? = nil
}

@Model private struct UndoArrayHost {
    var hooks: [any CollectionHook] = []
    func onActivate() { node.trackUndo() }
}

@Model private struct PlainExistentialArrayHost {
    var labels: [any CustomStringConvertible] = []
}

private func isAlive(_ model: some Model) -> Bool { model.lifetime == .active }

@Suite(.modelTesting(exhaustivity: .off))
struct ExistentialCollectionTests {
    @Test func initialElementsAreAnchoredAndActivated() async throws {
        let host = ArrayHost(hooks: [CountHook(), OtherHook()]).withAnchor()
        let a = try #require(host.hooks[0] as? CountHook)
        let b = try #require(host.hooks[1] as? OtherHook)
        #expect(isAlive(a) && isAlive(b))
        await expect(a.activations == 1 && b.activations == 1)
        a.count = 5
        await expect(host.total == 105)
    }

    @Test func appendRemoveAndReplace() async throws {
        let host = ArrayHost().withAnchor()
        host.hooks.append(CountHook())
        host.hooks.append(OtherHook())
        let a = try #require(host.hooks[0] as? CountHook)
        let b = try #require(host.hooks[1] as? OtherHook)
        #expect(isAlive(a) && isAlive(b))
        await expect(a.activations == 1)

        host.hooks.removeFirst()
        #expect(a.lifetime == .destructed)
        #expect(isAlive(b))

        host.hooks[0] = CountHook()
        #expect(b.lifetime == .destructed)
        let c = try #require(host.hooks[0] as? CountHook)
        #expect(isAlive(c))

        host.hooks = []
        #expect(c.lifetime == .destructed)
    }

    @Test func reorderingKeepsTheLiveElements() async throws {
        let host = ArrayHost(hooks: [CountHook(), OtherHook()]).withAnchor()
        let a = try #require(host.hooks[0] as? CountHook)
        let b = try #require(host.hooks[1] as? OtherHook)
        await expect(a.activations == 1 && b.activations == 1)
        host.hooks.reverse()
        #expect(isAlive(a) && isAlive(b))
        // Not re-activated: the same live children, moved.
        await expect(a.activations == 1 && b.activations == 1)
        a.count = 1
        await expect(host.total == 101)
    }

    @Test func optionalElements() async throws {
        let host = ArrayHost(optionalHooks: [CountHook(), nil]).withAnchor()
        let a = try #require(host.optionalHooks[0] as? CountHook)
        #expect(isAlive(a))
        host.optionalHooks[1] = OtherHook()
        let b = try #require(host.optionalHooks[1] as? OtherHook)
        #expect(isAlive(b))
        host.optionalHooks[0] = nil
        #expect(a.lifetime == .destructed)
    }

    @Test func dictionaryValues() async throws {
        let host = ArrayHost().withAnchor()
        host.byName["a"] = CountHook()
        host.byName["b"] = OtherHook()
        let a = try #require(host.byName["a"] as? CountHook)
        let b = try #require(host.byName["b"] as? OtherHook)
        #expect(isAlive(a) && isAlive(b))
        await expect(a.activations == 1)
        host.byName["a"] = nil
        #expect(a.lifetime == .destructed)
        host.byName["b"] = CountHook()
        #expect(b.lifetime == .destructed)
        #expect(isAlive(try #require(host.byName["b"] as? CountHook)))
    }

    @Test func elementEventsReachTheParent() async throws {
        let host = ArrayHost(hooks: [EventHook(count: 7)]).withAnchor()
        let e = try #require(host.hooks[0] as? EventHook)
        e.tap()
        await expect(host.lastTap == 7)
    }

    @Test func elementsAreInTheHierarchy() async {
        let host = ArrayHost(hooks: [CountHook(), OtherHook()], byName: ["x": CountHook()]).withAnchor()
        let names = host.node.reduceHierarchy(for: [.descendants], transform: { "\(type(of: $0))" }, into: [String]()) { $0.append($1) }
        #expect(names.sorted() == ["CountHook", "CountHook", "OtherHook"])
    }

    @Test func frozenCopyFreezesTheElements() async throws {
        let host = ArrayHost(hooks: [CountHook()]).withAnchor()
        let copy = host.frozenCopy
        #expect((copy.hooks[0] as? CountHook)?.lifetime == .frozenCopy)
        #expect(isAlive(try #require(host.hooks[0] as? CountHook)))
    }

    @Test func undoRestoresRemovedElements() async throws {
        let stack = ModelUndoStack()
        let host = UndoArrayHost(hooks: [CountHook()]).withAnchor { $0.undoSystem.backend = stack }
        host.hooks.append(OtherHook())
        await expect(host.hooks.count == 2)
        host.hooks.removeAll()
        await expect(host.hooks.isEmpty)
        stack.undo()
        await expect(host.hooks.count == 2)
        let a = try #require(host.hooks[0] as? CountHook)
        #expect(isAlive(a))
        a.count = 3
        await expect(a.count == 3)
    }

    @Test func anAppendedElementActivatesItsDescendants() async throws {
        let host = ArrayHost(hooks: [CountHook()]).withAnchor()
        host.hooks.append(NestingHook())
        let nesting = try #require(host.hooks[1] as? NestingHook)
        await expect(nesting.activations == 1 && nesting.inner.activated)
        // The existing element was not activated again.
        let first = try #require(host.hooks[0] as? CountHook)
        await expect(first.activations == 1)
    }

    @Test func optionalCollection() async throws {
        let host = OptionalArrayHost().withAnchor()
        host.hooks = [CountHook()]
        let a = try #require(host.hooks?[0] as? CountHook)
        #expect(isAlive(a))
        await expect(a.activations == 1)
        host.hooks?.append(OtherHook())
        let b = try #require(host.hooks?[1] as? OtherHook)
        #expect(isAlive(b))
        let copy = host.frozenCopy
        #expect((copy.hooks?[1] as? OtherHook)?.lifetime == .frozenCopy)
        host.hooks = nil
        #expect(a.lifetime == .destructed && b.lifetime == .destructed)
    }

    @Test func plainExistentialArraysStayPlainValues() async {
        let host = PlainExistentialArrayHost().withAnchor()
        host.labels.append(1)
        host.labels.append("two")
        await expect(host.labels.map(\.description) == ["1", "two"])
    }
}

@Suite(.modelTesting)
struct ExistentialCollectionExhaustiveTests {
    @Test func elementWritesAreTrackedExhaustively() async throws {
        let host = ArrayHost(hooks: [CountHook()]).withAnchor()
        await settle()
        let a = try #require(host.hooks[0] as? CountHook)
        a.count = 2
        await expect(a.count == 2)
        host.hooks.append(OtherHook())
        let b = try #require(host.hooks[1] as? OtherHook)
        await expect {
            host.hooks.count == 2
            b.activations == 1
        }
    }
}
