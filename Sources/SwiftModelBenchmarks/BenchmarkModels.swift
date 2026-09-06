import SwiftModel
import IdentifiedCollections

// MARK: - Simple counter

/// Minimal model: one Int property and one event. Used for activation, read, and write benchmarks.
@Model struct BenchCounter: Sendable {
    var count: Int = 0
    enum Event: Sendable { case increment }
}

// MARK: - List with children

/// Child model placed inside BenchList. Each instance is a separate context node.
@Model struct BenchItem: Sendable, Identifiable {
    let id: Int
    var value: Int = 0
    var label: String = ""
    enum Event: Sendable { case tapped }
}

/// Root model holding a wide array of children. Used for hierarchy activation/mutation benchmarks.
@Model struct BenchList: Sendable {
    var items: IdentifiedArrayOf<BenchItem> = []
    var selectedID: Int? = nil
    enum Event: Sendable { case selectionChanged(Int?) }
}

// MARK: - Parent / child pair

/// Used for event-dispatch and onChange benchmarks: child sends events, parent reacts.
@Model struct BenchParent: Sendable {
    var child: BenchChild = BenchChild()
    var count: Int = 0
    enum Event: Sendable { case childUpdated }

    func onActivate() {
        node.forEach(node.event(fromType: BenchChild.self)) { event, _ in
            count += 1
        }
    }
}

@Model struct BenchChild: Sendable {
    var value: Int = 0
    enum Event: Sendable { case updated }
}

// MARK: - Array list (Array<@Model>)

/// Root model holding a plain Swift Array of children.
/// `Array<BenchItem: @Model & Identifiable>` conforms to `ModelContainer` via the library's
/// `extension Array: ModelContainer where Element: ModelContainer & Identifiable`.
/// Uses the cursor-based `MutableCollection.visit` path with `shouldSkipElement` fast path.
@Model struct BenchArrayList: Sendable {
    var items: [BenchItem] = []
}

// MARK: - ContainerCollection (IdentifiedArray<@ModelContainer enum>)

/// A @ModelContainer enum whose cases hold @Model children.
/// Used to benchmark IdentifiedArray<BenchPath> — an IdentifiedArray of ModelContainer elements.
@ModelContainer enum BenchPath: Identifiable, Sendable {
    case item(BenchItem)
    case counter(BenchCounter)

    var id: Int {
        switch self {
        case .item(let m): return m.id
        case .counter: return -1
        }
    }
}

/// Root model holding a wide IdentifiedArray of BenchPath elements.
/// The IdentifiedArray is NOT itself ModelContainer — uses visitContainerCollection.
@Model struct BenchContainerList: Sendable {
    var paths: IdentifiedArrayOf<BenchPath> = []
}

// MARK: - Write cost vs state size (snapshot-reads spike)

/// Models of increasing `_State` size, each written through ONE scalar (`a`). With
/// snapshot-published reads every write copies the whole `_State` into a fresh box, so
/// the per-write cost grows with the number (and refcount-ness) of the fields, not with
/// the size of any one collection (a COW buffer is one retain). Section 2f measures that.
@Model struct BenchScalars2: Sendable {
    var a: Int = 0
    var b: Int = 0
}

@Model struct BenchScalars10: Sendable {
    var a: Int = 0
    var p1: Int = 0
    var p2: Int = 0
    var p3: Int = 0
    var p4: Int = 0
    var p5: Int = 0
    var p6: Int = 0
    var p7: Int = 0
    var p8: Int = 0
    var p9: Int = 0
}

@Model struct BenchScalars30: Sendable {
    var a: Int = 0
    var p1: Int = 0
    var p2: Int = 0
    var p3: Int = 0
    var p4: Int = 0
    var p5: Int = 0
    var p6: Int = 0
    var p7: Int = 0
    var p8: Int = 0
    var p9: Int = 0
    var p10: Int = 0
    var p11: Int = 0
    var p12: Int = 0
    var p13: Int = 0
    var p14: Int = 0
    var p15: Int = 0
    var p16: Int = 0
    var p17: Int = 0
    var p18: Int = 0
    var p19: Int = 0
    var p20: Int = 0
    var p21: Int = 0
    var p22: Int = 0
    var p23: Int = 0
    var p24: Int = 0
    var p25: Int = 0
    var p26: Int = 0
    var p27: Int = 0
    var p28: Int = 0
    var p29: Int = 0
}

/// 30 heap-backed strings: the refcounted-field variant of `BenchScalars30` — a state copy
/// here is 30 retains + 30 releases, where the Int variant is a memcpy.
@Model struct BenchStrings30: Sendable {
    var a: Int = 0
    var s1 = "a string long enough to live on the heap"
    var s2 = "a string long enough to live on the heap"
    var s3 = "a string long enough to live on the heap"
    var s4 = "a string long enough to live on the heap"
    var s5 = "a string long enough to live on the heap"
    var s6 = "a string long enough to live on the heap"
    var s7 = "a string long enough to live on the heap"
    var s8 = "a string long enough to live on the heap"
    var s9 = "a string long enough to live on the heap"
    var s10 = "a string long enough to live on the heap"
    var s11 = "a string long enough to live on the heap"
    var s12 = "a string long enough to live on the heap"
    var s13 = "a string long enough to live on the heap"
    var s14 = "a string long enough to live on the heap"
    var s15 = "a string long enough to live on the heap"
    var s16 = "a string long enough to live on the heap"
    var s17 = "a string long enough to live on the heap"
    var s18 = "a string long enough to live on the heap"
    var s19 = "a string long enough to live on the heap"
    var s20 = "a string long enough to live on the heap"
    var s21 = "a string long enough to live on the heap"
    var s22 = "a string long enough to live on the heap"
    var s23 = "a string long enough to live on the heap"
    var s24 = "a string long enough to live on the heap"
    var s25 = "a string long enough to live on the heap"
    var s26 = "a string long enough to live on the heap"
    var s27 = "a string long enough to live on the heap"
    var s28 = "a string long enough to live on the heap"
    var s29 = "a string long enough to live on the heap"
    var s30 = "a string long enough to live on the heap"
}

/// One scalar next to a 500-element collection of child models.
@Model struct BenchWide500: Sendable {
    var a: Int = 0
    var items: IdentifiedArrayOf<BenchItem> = []
}

// MARK: - onChange model

/// Reacts to its own counter changes via onChange. Used to benchmark the observation / coalescing path.
@Model struct BenchWatcher: Sendable {
    var trigger: Int = 0
    var reactionCount: Int = 0

    func onActivate() {
        node.onChange(of: trigger, initial: false) { _, _ in
            reactionCount += 1
        }
    }
}
