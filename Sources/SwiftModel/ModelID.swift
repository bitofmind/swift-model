import Foundation
import ConcurrencyExtras

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
