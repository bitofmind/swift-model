import Testing
@testable import SwiftModel
import SwiftModel

// Regression tests for a Swift compiler bug in key paths formed in a generic context whose
// subscript index has a layout that depends on a generic parameter (e.g. `\S[i: Idx<V>(…)]`
// inside `func f<V>`). The call site packs the index into the key path's argument buffer at
// pointer-size offset without aligning it, while the generated argument-init thunk reads it
// back at the offset rounded up to the index's alignment. Any index aligned beyond a
// pointer is therefore read as garbage — a wrong value, or a trap in `keypath_destroy`.
//
// On wasm32 (4-byte pointers) that is every 8-byte-aligned value: `LocalStorage<UInt64>`,
// `Int64`, `Double`. On 64-bit hosts it takes a 16-byte-aligned value, which is what these
// tests use (`SIMD2<Double>`) so the regular macOS/Linux runs catch a regression.
// `scripts/wasm-smoke` covers the 8-byte-aligned wasm32 case.
//
// SwiftModel forms such key paths for context storage (`[_metadata:]`), preferences
// (`[_preference:]`) and container elements (`[cursor:]`), so each index type must keep a
// layout that doesn't depend on the user's value type.

private typealias Wide = SIMD2<Double>

private struct WideID: Hashable, Sendable {
    var value: Wide
}

private extension LocalKeys {
    var wideLocal: LocalStorage<Wide> { .init(defaultValue: Wide(1, 2)) }
}

private extension EnvironmentKeys {
    var wideEnvironment: EnvironmentStorage<Wide> { .init(defaultValue: Wide(3, 4)) }
}

private extension PreferenceKeys {
    var wideSum: PreferenceStorage<Wide> {
        .init(defaultValue: Wide(0, 0), key: "wideSum") { $0 += $1 }
    }
}

@Model
private struct WideRow: Identifiable {
    let id: WideID
    var count: Int = 0
}

@Model
private struct WideRowParent {
    var rows: [WideRow] = []
}

@Model
private struct WideStorageModel {
    var child: WideRow = WideRow(id: WideID(value: Wide(7, 8)))
}

@Suite(.modelTesting)
struct OverAlignedKeyPathIndexTests {
    @Test func overAlignedLocalStorage() async {
        #expect(MemoryLayout<Wide>.alignment > MemoryLayout<UnsafeRawPointer>.alignment)
        let model = WideStorageModel().withAnchor()
        #expect(model.node.local.wideLocal == Wide(1, 2))

        model.node.local.wideLocal = Wide(5, 6)
        await expect(model.node.local.wideLocal == Wide(5, 6))
    }

    @Test func overAlignedEnvironmentStorage() async {
        let model = WideStorageModel().withAnchor()
        #expect(model.child.node.environment.wideEnvironment == Wide(3, 4))

        model.node.environment.wideEnvironment = Wide(9, 10)
        await expect {
            model.node.environment.wideEnvironment == Wide(9, 10)
            model.child.node.environment.wideEnvironment == Wide(9, 10)
        }
    }

    @Test func overAlignedPreference() async {
        let model = WideStorageModel().withAnchor()
        #expect(model.node.preference.wideSum == Wide(0, 0))

        model.node.preference.wideSum = Wide(1, 1)
        model.child.node.preference.wideSum = Wide(2, 3)
        await expect {
            model.node.preference.wideSum == Wide(3, 4)
            model.child.node.preference.wideSum == Wide(2, 3)
        }
    }

    @Test func overAlignedContainerElementID() async {
        let model = WideRowParent().withAnchor()

        model.rows.append(WideRow(id: WideID(value: Wide(1, 1))))
        model.rows.append(WideRow(id: WideID(value: Wide(2, 2))))
        await expect(model.rows.map(\.id.value) == [Wide(1, 1), Wide(2, 2)])

        model.rows[1].count += 1
        await expect(model.rows[1].count == 1)
    }
}
