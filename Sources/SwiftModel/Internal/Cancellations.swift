import Foundation

/// Diagnostic snapshot of a subtree's work units. `parkGeneration` is the sum
/// of every live unit's park/unpark transition count — it changes iff some unit
/// parked or unparked, which is design §5's "no flicker between two
/// observations" check.
struct _WorkUnitCensus {
    var registered = 0
    var parked = 0
    var parkGeneration: UInt64 = 0
}

/// One entry in `Cancellations.liveWorkUnits` — a `TaskCancellable`'s work
/// unit plus the identity the diagnostics need.
struct _LiveWorkUnit {
    let id: Int
    let modelName: String
    let taskName: String
    let fileAndLine: FileAndLine
    let unit: ModelWorkUnit
}

final class Cancellations: @unchecked Sendable {
    fileprivate let lock = NSLock()
    fileprivate var registered: [Int: InternalCancellable] = [:]
    fileprivate var keyed: [CancellableKey: [Int]] = [:]
    private var _sealed = false

    /// SEMANTIC QUIESCENCE — the set of task bodies that are still ABLE TO RUN.
    ///
    /// This is deliberately NOT `registered`. `registered` is the
    /// *cancellation* registry, and cancelling drops an entry **before** the
    /// task has unwound: `cancel(_:)` goes through `unregister`, and
    /// `cancelAll()` empties the dictionary and only then calls `onCancel()`.
    /// A cancelled body keeps running through its `defer`s afterwards, and
    /// those routinely write model state —
    ///
    ///     node.task {
    ///         defer { playerController = nil; marker = "cleared" }   // <- writes
    ///         ...
    ///     }
    ///
    /// — so an answer derived from `registered` reads "quiescent" during every
    /// teardown, `task(id:)` replacement and `cancelPrevious` swap while model
    /// writes are still to come. That is the same premature-pass shape as the
    /// `catch`-handler window (see `TaskCancellable`'s `defer { onDone() }`),
    /// and it is much more common.
    ///
    /// Entries are inserted at registration and removed by exactly one thing:
    /// the task body's outermost `defer`, via `retireWorkUnit(_:)`. So the unit
    /// outlives cancellation and is retired only when the body genuinely cannot
    /// run again. (The one path where the body never runs — cancelled before
    /// `TaskCancellable.init` creates the `Task` — retires explicitly there.)
    private var liveWorkUnits: [Int: _LiveWorkUnit] = [:]

    deinit {
        cancelAll()
    }

    func cancel(_ c: InternalCancellable) {
        unregister(c.id)?.onCancel()
    }

    func cancel<Key: Hashable&Sendable>(_ c: InternalCancellable, for key: Key, cancelInFlight: Bool) {
        if cancelInFlight {
            cancelAll(for: key)
        }

        lock {
            guard registered[c.id] != nil else { return }
            keyed[.init(key: key), default: []].append(c.id)
        }
    }

    func seal() {
        lock { _sealed = true }
    }

    func register(_ c: InternalCancellable) {
        let shouldImmediatelyCancel: Bool = lock {
            // Sealed: no `Task` is ever created for this cancellable, so nothing
            // will call `retireWorkUnit`. Registering a live unit here would
            // pin the model as permanently non-quiescent.
            if _sealed { return true }
            registered[c.id] = c
            if let task = c as? TaskCancellable {
                liveWorkUnits[c.id] = _LiveWorkUnit(
                    id: task.id,
                    modelName: task.modelName,
                    taskName: task.taskName,
                    fileAndLine: task.fileAndLine,
                    unit: task.workUnit
                )
            }
            for key in AnyCancellable.contexts {
                keyed[key, default: []].append(c.id)
            }
            return false
        }
        if shouldImmediatelyCancel {
            c.onCancel()
        }
    }

    /// Drops the live work unit for `id`. Called from the task body's outermost
    /// `defer` (and from the never-started path in `TaskCancellable.init`) —
    /// see `liveWorkUnits`.
    func retireWorkUnit(_ id: Int) {
        lock { _ = liveWorkUnits.removeValue(forKey: id) }
    }

    func unregister(_ id: Int) -> InternalCancellable? {
        lock {
            let cancellable = registered.removeValue(forKey: id)

            for contextAndKey in keyed.keys {
                while let index = keyed[contextAndKey]?.firstIndex(of: id) {
                    keyed[contextAndKey]?.remove(at: index)
                }
                if keyed[contextAndKey]?.isEmpty == true {
                    keyed[contextAndKey] = nil
                }
            }

            return cancellable
        }
    }

    func cancelAll(for key: some Hashable&Sendable) {
        lock {
            (keyed.removeValue(forKey: .init(key: key)) ?? []).compactMap { id in
                registered.removeValue(forKey: id)
            }
        }.forEach {
            $0.onCancel()
        }
    }

    var activeTasks: [(modelName: String, tasks: [(name: String, fileAndLine: FileAndLine)])] {
        lock {
            // Sort by task ID (registration order) for stable diagnostic output.
            registered.values.reduce(into: [String: [(id: Int, name: String, fileAndLine: FileAndLine)]]()) { dict, c in
                if let task = c as? TaskCancellable {
                    dict[task.modelName, default: []].append((task.id, task.taskName, task.fileAndLine))
                }
            }.map { modelName, triples in
                (modelName: modelName, tasks: triples.sorted { $0.id < $1.id }.map { ($0.name, $0.fileAndLine) })
            }
        }
    }

    /// True if any registered `TaskCancellable` has not yet had its body
    /// scheduled past its first CPU slot. Used by `TestAccess.settle()` to
    /// hold open the quiet window until every freshly-registered task has at
    /// least started running — otherwise an `onActivate` task that's still
    /// sitting in the cooperative pool's queue can write a tracked property
    /// AFTER settle's exhaustivity baseline has been reset.
    /// See `TaskCancellable.hasStartedRunning` and
    /// `ModelAccess.taskBodyStarted`.
    var hasPendingStartTask: Bool {
        lock {
            registered.values.contains { ($0 as? TaskCancellable)?.hasStartedRunning == false }
        }
    }

    /// SEMANTIC QUIESCENCE (computed, not yet used for verdicts).
    ///
    /// True if any registered work unit in this registry is **running** — i.e.
    /// executing, or suspended somewhere SwiftModel did not put it. Work parked
    /// at a suspension the framework owns (`forEach`'s `next()`, anything inside
    /// `withModelParked`) does not count. See `ModelWorkUnit`.
    var hasRunningWorkUnit: Bool {
        lock {
            liveWorkUnits.values.contains { $0.unit.isRunning }
        }
    }

    /// `(registered task-unit count, parked count)` for this registry.
    /// Diagnostic only: it is what separates the two shapes of "new says
    /// quiescent, old says busy". A snapshot with **parked > 0** is a work unit
    /// whose continuation may already have been resumed while its `unpark()`
    /// has not run yet (design §5's park→resume window); a snapshot with
    /// **registered == 0** is an executor job that owns no unit at all, which is
    /// where an unregistered-work hole would hide.
    var workUnitCensus: _WorkUnitCensus {
        lock {
            var census = _WorkUnitCensus()
            for entry in liveWorkUnits.values {
                census.registered += 1
                if !entry.unit.isRunning { census.parked += 1 }
                census.parkGeneration &+= entry.unit.parkGeneration
            }
            return census
        }
    }

    /// The running work units, for the disagreement trace / future backstop
    /// message. Sorted by registration order for stable output.
    var runningWorkUnits: [(modelName: String, name: String, fileAndLine: FileAndLine)] {
        lock {
            liveWorkUnits.values
                .filter { $0.unit.isRunning }
                .sorted { $0.id < $1.id }
                .map { (modelName: $0.modelName, name: $0.taskName, fileAndLine: $0.fileAndLine) }
        }
    }

    func cancelAll() {
        lock {
            defer {
                registered.removeAll()
                keyed.removeAll()
            }
            return registered.values
        }.forEach {
            $0.onCancel()
        }
    }

    var _nextId = 0
    var nextId: Int {
        lock {
            _nextId += 1
            return _nextId
        }
    }
}

protocol InternalCancellable {
    var id: Int { get }
    func onCancel()
}

enum ContextCancellationKey {
    case onActivate
}

struct CancellableKey: Hashable, @unchecked Sendable {
    var key: AnyHashable

    init<Key: Hashable&Sendable>(key: Key) {
        if let key = key as? CancellableKey {
            self.key = key.key
        } else {
            self.key = key
        }
    }
}

package struct FileAndLine: Hashable, Sendable {
    package var fileID: StaticString
    package var filePath: StaticString
    package var line: UInt
    package var column: UInt

    package init(fileID: StaticString, filePath: StaticString, line: UInt, column: UInt) {
        self.fileID = fileID
        self.filePath = filePath
        self.line = line
        self.column = column
    }

    package static func == (lhs: FileAndLine, rhs: FileAndLine) -> Bool {
        lhs.line == rhs.line && lhs.column == rhs.column
        && lhs.fileID.description == rhs.fileID.description
        && lhs.filePath.description == rhs.filePath.description
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(fileID.description)
        hasher.combine(filePath.description)
        hasher.combine(line)
        hasher.combine(column)
    }
}
extension FileAndLine: CustomStringConvertible {
    /// Returns `"filename.swift:line"` — the last path component of `fileID` plus the line number.
    /// This is used as the memoize label when no explicit string key is provided.
    package var description: String {
        let filename = fileID.description.split(separator: "/").last.map(String.init) ?? fileID.description
        return "\(filename):\(line)"
    }
}

