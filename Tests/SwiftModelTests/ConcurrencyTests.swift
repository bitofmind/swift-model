import Testing
import ConcurrencyExtras
import Foundation
@testable import SwiftModel

// MARK: - Keys

private extension ContextKeys {
    var concurrentInt: ContextStorage<Int> { .init(defaultValue: 0) }
    var concurrentString: ContextStorage<String> { .init(defaultValue: "initial", propagation: .environment) }
}

private extension PreferenceKeys {
    var concurrentSum: PreferenceStorage<Int> { .init(defaultValue: 0, key: "concurrentSum") { $0 += $1 } }
}

// MARK: - Models

@Model
private struct ConcurrentLeaf {
    var value: Int = 0
}

@Model
private struct ConcurrentParent {
    var child: ConcurrentLeaf = ConcurrentLeaf()
    var count: Int = 0
}

@Model
private struct ConcurrentGrandparent {
    var parent: ConcurrentParent = ConcurrentParent()
}

// MARK: - ConcurrencyTests
//
// These tests stress-test thread safety of contextStorage and preferenceStorage reads/writes
// by firing concurrent reads and writes from multiple Tasks at the same time.
//
// Before the fix in ModelContextStorage.swift (locked reads), the contextStorage getter read
// the dictionary without holding the lock while the setter held the lock. Under TSAN or
// simply under heavy parallelism, this manifested as a corrupted dictionary crash
// (e.g. garbage NSIndexPath in AnyHashableSendable).

struct ConcurrencyTests {

    // MARK: - contextStorage: concurrent local read/write

    /// Hammers concurrent reads and writes of a local (non-environment) context storage key.
    /// Before the fix, the unlocked getter raced against the locked setter.
    @Test func contextStorageConcurrentLocalReadWrite() async {
        let model = ConcurrentLeaf().withAnchor()
        let iterations = 500

        await withTaskGroup(of: Void.self) { group in
            // Writer task: sets the key to incrementing integers.
            group.addTask {
                for i in 0..<iterations {
                    model.node.context.concurrentInt = i
                }
            }
            // Reader task: reads the key concurrently with the writer.
            group.addTask {
                var lastSeen = 0
                for _ in 0..<iterations {
                    let v = model.node.context.concurrentInt
                    // Value must always be a non-negative integer — never garbage.
                    #expect(v >= 0)
                    lastSeen = v
                }
                _ = lastSeen
            }
        }
    }

    // MARK: - contextStorage: concurrent environment read/write

    /// Hammers concurrent reads (environment walk) and writes of an environment-propagating
    /// context storage key on a two-level hierarchy.
    /// This exercises both the `subscript` getter (fix #1) and `environmentValue(for:)` (fix #2).
    @Test func contextStorageConcurrentEnvironmentReadWrite() async {
        let parent = ConcurrentParent().withAnchor()
        let iterations = 500

        await withTaskGroup(of: Void.self) { group in
            // Writer writes on the parent.
            group.addTask {
                for i in 0..<iterations {
                    parent.node.context.concurrentString = "value-\(i)"
                }
            }
            // Reader reads the inherited value from the child (walks up via environmentValue).
            group.addTask {
                for _ in 0..<iterations {
                    let v = parent.child.node.context.concurrentString
                    // Must always start with "value-" or be the default "initial".
                    #expect(v == "initial" || v.hasPrefix("value-"))
                }
            }
        }
    }

    // MARK: - contextStorage: many concurrent writers

    /// Multiple concurrent writers on the same local key — verifies the locked setter doesn't
    /// deadlock and the final value is a valid integer written by one of the writers.
    @Test func contextStorageManyWriters() async {
        let model = ConcurrentLeaf().withAnchor()
        let writerCount = 10
        let iterationsPerWriter = 100

        await withTaskGroup(of: Void.self) { group in
            for w in 0..<writerCount {
                let writerID = w
                group.addTask {
                    for i in 0..<iterationsPerWriter {
                        model.node.context.concurrentInt = writerID * iterationsPerWriter + i
                    }
                }
            }
        }

        // After all writers finish, the value must be in the valid range.
        let final = model.node.context.concurrentInt
        #expect(final >= 0 && final < writerCount * iterationsPerWriter)
    }

    // MARK: - contextStorage: concurrent read/write across hierarchy levels

    /// Writes are done on the grandparent while reads walk from the leaf up through parent and
    /// grandparent. This stresses the `reduceHierarchy` traversal inside `environmentValue(for:)`,
    /// where each visited context's `contextStorage` must be read under that context's lock.
    @Test func contextStorageConcurrentHierarchyReadWrite() async {
        let root = ConcurrentGrandparent().withAnchor()
        let iterations = 300

        await withTaskGroup(of: Void.self) { group in
            // Writer alternates between setting and clearing the environment value on the root.
            group.addTask {
                for i in 0..<iterations {
                    root.node.context.concurrentString = "env-\(i)"
                }
            }
            // Reader reads from the deepest descendant, forcing a full ancestor walk.
            group.addTask {
                for _ in 0..<iterations {
                    let v = root.parent.child.node.context.concurrentString
                    #expect(v == "initial" || v.hasPrefix("env-"))
                }
            }
            // Second reader on the intermediate parent.
            group.addTask {
                for _ in 0..<iterations {
                    let v = root.parent.node.context.concurrentString
                    #expect(v == "initial" || v.hasPrefix("env-"))
                }
            }
        }
    }

    // MARK: - preferenceStorage: concurrent read/write

    /// Hammers concurrent reads (aggregate walk) and writes of a preference key.
    /// `preferenceStorage` reads have always been locked (correct pattern), so this is a
    /// regression guard to ensure we don't accidentally break that invariant.
    @Test func preferenceStorageConcurrentReadWrite() async {
        let root = ConcurrentParent().withAnchor()
        let iterations = 500

        await withTaskGroup(of: Void.self) { group in
            // Writer sets contributions on both parent and child.
            group.addTask {
                for i in 0..<iterations {
                    root.node.preference.concurrentSum = i
                    root.child.node.preference.concurrentSum = i + 1
                }
            }
            // Reader aggregates from the root (walks self + descendants).
            group.addTask {
                for _ in 0..<iterations {
                    let v = root.node.preference.concurrentSum
                    // Aggregate is always >= 0.
                    #expect(v >= 0)
                }
            }
        }
    }

    // MARK: - contextStorage: concurrent read/write with model property mutations

    /// Interleaves context storage reads/writes with regular model property mutations.
    /// This is the real-world scenario that triggered the original crash: a background
    /// task read contextStorage while the main-thread SwiftUI frame write was happening.
    @Test func contextStorageConcurrentWithModelMutations() async {
        let model = ConcurrentParent().withAnchor()
        let iterations = 500

        await withTaskGroup(of: Void.self) { group in
            // Mutates a regular @Model property.
            group.addTask {
                for i in 0..<iterations {
                    model.count = i
                }
            }
            // Concurrently writes contextStorage.
            group.addTask {
                for i in 0..<iterations {
                    model.node.context.concurrentInt = i
                }
            }
            // Concurrently reads contextStorage.
            group.addTask {
                for _ in 0..<iterations {
                    let v = model.node.context.concurrentInt
                    #expect(v >= 0)
                }
            }
        }
    }

    // MARK: - contextStorage: remove concurrent with reads

    /// Concurrent `removeEnvironmentValue` calls while readers are walking the hierarchy.
    /// Before the fix, removeEnvironmentValue held the lock but `environmentValue` read
    /// without it, causing a race on the dictionary during removal.
    @Test func contextStorageConcurrentRemoveAndRead() async {
        let root = ConcurrentGrandparent().withAnchor()
        let iterations = 200

        await withTaskGroup(of: Void.self) { group in
            // Alternates between setting and removing the environment value.
            group.addTask {
                for i in 0..<iterations {
                    if i % 2 == 0 {
                        root.node.context.concurrentString = "set-\(i)"
                    } else {
                        root.node.removeContext(\.concurrentString)
                    }
                }
            }
            // Reads during the set/remove cycle.
            group.addTask {
                for _ in 0..<iterations {
                    let v = root.parent.child.node.context.concurrentString
                    #expect(v == "initial" || v.hasPrefix("set-"))
                }
            }
        }
    }
}
