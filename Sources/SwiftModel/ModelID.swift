import Foundation
import Dependencies

/// A stable, unique identity value assigned to each live model instance.
///
/// Every `@Model` struct receives a `ModelID` when it is anchored into the hierarchy.
/// The ID is stable for the lifetime of the context — it does not change when the model's
/// stored properties are mutated — and is used internally to track parent–child relationships,
/// drive `Identifiable` conformance, and detect when two model values refer to the same live instance.
///
/// You rarely need to interact with `ModelID` directly. Access it via `model.id`, which is
/// provided by the synthesised `Identifiable` conformance.
public struct ModelID: Hashable, Sendable, CustomReflectable, CustomStringConvertible, CustomDebugStringConvertible {
    private var low: UInt32
    private var high: UInt16

    public var customMirror: Mirror {
        Mirror(self, children: [])
    }

    /// Returns the ID in the form `"ModelID(5)"`, making it clear in diffs and debug output
    /// that this is the auto-generated instance identity rather than a user-declared property.
    public var description: String {
        "ModelID(\(UInt64(high) << 32 | UInt64(low)))"
    }

    @inlinable public var debugDescription: String { description }
}

extension ModelID {
    private mutating func increment() {
        low = low &+ 1
        if low == 0 { // Wrapped around?
            high = high &+ 1
        }
    }

    private static let last = LockIsolated(ModelID(low: 0, high: 0))
    static func generate() -> Self {
        last.withValue {
            $0.increment()
            return $0
        }
    }
}
