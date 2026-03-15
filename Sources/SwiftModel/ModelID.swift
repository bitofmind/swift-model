import Foundation
import ConcurrencyExtras

/// A stable, unique identity value assigned to each live model instance.
///
/// Every `@Model` struct receives a `ModelID` when it is anchored into the hierarchy.
/// The ID is stable for the lifetime of the context — it does not change when the model's
/// stored properties are mutated — and is used internally to track parent–child relationships,
/// drive `Identifiable` conformance, and detect when two model values refer to the same live instance.
///
/// You rarely need to interact with `ModelID` directly. Access it via `model.id` (provided by
/// the synthesised `Identifiable` conformance) or `node.id`.
public struct ModelID: Hashable, Sendable, CustomReflectable, CustomDebugStringConvertible {
    private var low: UInt32
    private var high: UInt16

    public var customMirror: Mirror {
        Mirror(self, children: [])
    }

    public var debugDescription: String {
        String(UInt64(high)<<32 | UInt64(low))
    }
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
