import Testing
import SwiftModel // plain import, like a downstream app: sees only the public `==` overloads

// SwiftModel's public `==` overloads returning `TestPredicate` exist for the `expect { a == b }`
// builder, so failures can print both sides. They're `@_disfavoredOverload`, so ordinary code
// outside a builder must keep inferring `Bool`. (The builder side is pinned by the
// `builder … == …` snapshots in `SwiftModelSnapshotTests/OutputSnapshotTests.swift`.)

private enum Outcome: Equatable, Sendable {
    case pending
    case needsNewPlayer
}

private struct Wrapper: Equatable, Sendable {
    var value: Int
}

/// Only accepts `Bool`: passing an untyped `let` here fails to compile if it inferred `TestPredicate`.
private func requireBool(_ value: Bool) -> Bool { value }

private func genericEquals<T: Equatable & Sendable>(_ lhs: T, _ rhs: T) -> Bool {
    let result = lhs == rhs
    return requireBool(result)
}

struct TestPredicateOverloadTests {
    @Test func equalityOutsideBuilderInfersBool() {
        let outcome = Outcome.pending
        let immediate = outcome == .needsNewPlayer
        #expect(type(of: immediate) == Bool.self)
        #expect(requireBool(immediate) == false)
    }

    @Test func optionalEqualityOutsideBuilderInfersBool() {
        let count: Int? = 3
        let matches = count == 3
        #expect(type(of: matches) == Bool.self)
        #expect(requireBool(matches))
    }

    @Test func structEqualityOutsideBuilderInfersBool() {
        let a = Wrapper(value: 1)
        let b = Wrapper(value: 2)
        let same = a == b
        #expect(type(of: same) == Bool.self)
        #expect(requireBool(same) == false)
    }

    @Test func genericEqualityOutsideBuilderInfersBool() {
        #expect(genericEquals(Outcome.needsNewPlayer, .needsNewPlayer))
        #expect(genericEquals(Wrapper(value: 1), Wrapper(value: 2)) == false)
    }
}
