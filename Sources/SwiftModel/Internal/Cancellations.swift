import Foundation
import IssueReporting

final class Cancellations: @unchecked Sendable {
    fileprivate let lock = NSLock()
    fileprivate var registered: [Int: InternalCancellable] = [:]
    fileprivate var keyed: [CancellableKey: [Int]] = [:]
    private var _sealed = false

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
            if _sealed { return true }
            registered[c.id] = c
            for key in AnyCancellable.contexts {
                keyed[key, default: []].append(c.id)
            }
            return false
        }
        if shouldImmediatelyCancel {
            // Not while holding `lock` — `reportIssue` must never run inside a
            // context/cancellations critical section (see the AB-BA discussion
            // in Cancellables.swift); we're already outside it here.
            // A user `onCancel` handler that starts new work (`node.task { }`, a nested
            // `node.onCancel { }`, `forEach`, …) registers synchronously from inside a
            // teardown drain — on the store being drained, or another already-sealed one
            // (a parent torn down in the same removal). Report that; a registration racing
            // teardown from another thread is expected and stays silent (see the seal
            // ordering comment in `AnyContext.onRemoval`).
            if threadLocals.isDrainingCancellations {
                let subject = (c as? TaskCancellable).map {
                    "Task '\($0.taskName)' on `\($0.modelName)`"
                } ?? "A cancellable"
                let message = "\(subject) was registered while a model is being deactivated (from an `onCancel` handler); it is cancelled immediately and never runs. Work that must outlive a model belongs to a model that outlives it (e.g. start it with the parent's `node.task`)."
                if let fileAndLine = (c as? TaskCancellable)?.fileAndLine {
                    reportIssue(message, fileID: fileAndLine.fileID, filePath: fileAndLine.filePath, line: fileAndLine.line, column: fileAndLine.column)
                } else {
                    reportIssue(message)
                }
            }
            c.onCancel()
        }
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
        let cancellables = lock {
            (keyed.removeValue(forKey: .init(key: key)) ?? []).compactMap { id in
                registered.removeValue(forKey: id)
            }
        }
        threadLocals.withValue(true, at: \.isDrainingCancellations) {
            cancellables.forEach {
                $0.onCancel()
            }
        }
    }

    /// IDs of everything currently registered (SPIKE: used to tell mid-test teardown
    /// work from work the harness's own end-of-test teardown started).
    var registeredIDs: Set<Int> {
        lock { Set(registered.keys) }
    }

    var activeTasks: [(modelName: String, tasks: [(name: String, fileAndLine: FileAndLine)])] {
        activeTasks(only: nil)
    }

    func activeTasks(only ids: Set<Int>?) -> [(modelName: String, tasks: [(name: String, fileAndLine: FileAndLine)])] {
        lock {
            // Sort by task ID (registration order) for stable diagnostic output.
            registered.filter { ids?.contains($0.key) ?? true }.values.reduce(into: [String: [(id: Int, name: String, fileAndLine: FileAndLine)]]()) { dict, c in
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

    func cancelAll() {
        let cancellables = lock {
            defer {
                registered.removeAll()
                keyed.removeAll()
            }
            return registered.values
        }
        threadLocals.withValue(true, at: \.isDrainingCancellations) {
            cancellables.forEach {
                $0.onCancel()
            }
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

