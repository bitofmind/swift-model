import Foundation
import SwiftModel

// Each check exercises a code path that has broken on wasm32 before. It prints a line and
// exits non-zero on the first mismatch; a runtime trap fails the run too.
//
// Over-aligned key path indices: SwiftModel forms key paths in generic code whose subscript
// index used to embed the user's value type (`[_metadata: ContextStorage<V>]`,
// `[_preference: PreferenceStorage<V>]`, `[cursor: ContainerCursor<ID, …>]`). The Swift
// compiler misreads such an index when it is aligned beyond a pointer, which on wasm32 is
// any 8-byte-aligned type (`UInt64`, `Int64`, `Double`). That read back garbage or trapped
// with "null function" in `keypath_destroy`. See `OverAlignedKeyPathIndexTests`.

// Unbuffered, so a trap still shows every check that passed before it.
setvbuf(stdout, nil, _IONBF, 0)

nonisolated(unsafe) var failures = 0

func check<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    if actual == expected {
        print("ok   \(name)")
    } else {
        print("FAIL \(name): got \(actual), expected \(expected)")
        failures += 1
    }
}

extension LocalKeys {
    var smokeUInt64: LocalStorage<UInt64> { .init(defaultValue: 1) }
    var smokeInt64: LocalStorage<Int64> { .init(defaultValue: -2) }
    var smokeDouble: LocalStorage<Double> { .init(defaultValue: 3.5) }
}

extension EnvironmentKeys {
    var smokeEnvironmentDouble: EnvironmentStorage<Double> { .init(defaultValue: 4.5) }
}

extension PreferenceKeys {
    var smokeSum: PreferenceStorage<UInt64> {
        .init(defaultValue: 0, key: "smokeSum") { $0 += $1 }
    }
}

@Model
struct Row: Identifiable {
    let id: UInt64
    var count: Int = 0
}

@Model
struct Root {
    var rows: [Row] = [Row(id: 10), Row(id: 20)]
    var child: Row = Row(id: 99)

    var total: Int {
        node.memoize(for: "total") { rows.reduce(0) { $0 + $1.count } }
    }
}

let root = Root().withAnchor()

check("LocalStorage<UInt64> default", root.node.local.smokeUInt64, 1)
root.node.local.smokeUInt64 = .max
check("LocalStorage<UInt64> write", root.node.local.smokeUInt64, .max)

check("LocalStorage<Int64> default", root.node.local.smokeInt64, -2)
root.node.local.smokeInt64 = .min
check("LocalStorage<Int64> write", root.node.local.smokeInt64, .min)

check("LocalStorage<Double> default", root.node.local.smokeDouble, 3.5)
root.node.local.smokeDouble = 7.25
check("LocalStorage<Double> write", root.node.local.smokeDouble, 7.25)

check("EnvironmentStorage<Double> inherited default", root.child.node.environment.smokeEnvironmentDouble, 4.5)
root.node.environment.smokeEnvironmentDouble = 8.75
check("EnvironmentStorage<Double> inherited write", root.child.node.environment.smokeEnvironmentDouble, 8.75)

root.node.preference.smokeSum = 5
root.child.node.preference.smokeSum = 6
check("PreferenceStorage<UInt64> aggregate", root.node.preference.smokeSum, 11)

check("[Row] with UInt64 ids", root.rows.map(\.id), [10, 20])
root.rows.append(Row(id: .max))
root.rows[2].count = 3
root.rows[0].count = 1
check("[Row] element write", root.rows.map(\.count), [1, 0, 3])
check("memoize over [Row]", root.total, 4)
root.rows.removeFirst()
check("[Row] remove", root.rows.map(\.id), [20, .max])
check("memoize after remove", root.total, 3)

if failures > 0 {
    print("wasm smoke: \(failures) check(s) failed")
    exit(1)
}
print("wasm smoke: all checks passed")
