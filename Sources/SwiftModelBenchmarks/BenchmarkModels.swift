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
