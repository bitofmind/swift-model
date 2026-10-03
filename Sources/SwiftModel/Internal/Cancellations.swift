import Foundation
import IssueReporting

final class Cancellations: @unchecked Sendable {
    fileprivate let lock = NSLock()
    fileprivate var registered: [Int: InternalCancellable] = [:]
    fileprivate var keyed: [CancellableKey: [Int]] = [:]
    /// The keys each id is filed under in `keyed`, so removing an id touches only its
    /// own keys. Scanning all of `keyed` on every unregister hashed every key several
    /// times per cancel, which dominated a large model tree.
    private var keysByID: [Int: [CancellableKey]] = [:]
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

        let cancelNow: Bool = lock {
            guard registered[c.id] != nil else { return false }
            let key = CancellableKey(key: key)
            // Keying into a context that has already been cancelled: its cancel has run
            // and will never reach this one — cancel it now instead (see `ContextToken`).
            if key.contextToken?.isCancelled == true { return true }
            file(c.id, under: key)
            return false
        }
        if cancelNow {
            cancel(c)
        }
    }

    func seal() {
        lock { _sealed = true }
    }

    /// Sealed stores are being torn down (model removal / end-of-test teardown); an
    /// `onCancel()` arriving from one is a removal, not a user cancellation.
    var isSealed: Bool {
        lock { _sealed }
    }

    /// Registered cancellables of a given type (signal-handler lookup).
    func registered<T>(of type: T.Type) -> [T] {
        lock { registered.values.compactMap { $0 as? T } }
    }

    func register(_ c: InternalCancellable) {
        let contexts = AnyCancellable.contexts
        var inCancelledContext = false
        let shouldImmediatelyCancel: Bool = lock {
            if _sealed { return true }
            // Registered inside a context that has already been cancelled (e.g. a task
            // started by a task whose context was just cancelled): cancel at once, or
            // nothing ever would (see `ContextToken`).
            if contexts.contains(where: { $0.contextToken?.isCancelled == true }) {
                inCancelledContext = true
                return false
            }
            registered[c.id] = c
            for key in contexts {
                file(c.id, under: key)
            }
            return false
        }
        if inCancelledContext {
            c.onCancel()
            return
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
                let message = "\(subject) was registered while a model is being deactivated (from an `onCancel` handler); it is cancelled immediately and never runs. Register work that must run after removal while the model is live, with `node.onTeardown { … }` (or a signal handler's final call)."
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
            unfile(id)
            return cancellable
        }
    }

    /// Call under `lock`.
    private func file(_ id: Int, under key: CancellableKey) {
        keyed[key, default: []].append(id)
        keysByID[id, default: []].append(key)
    }

    /// Removes `id` from every key it is filed under. Call under `lock`.
    private func unfile(_ id: Int) {
        guard let keys = keysByID.removeValue(forKey: id) else { return }
        for key in keys {
            guard var ids = keyed[key] else { continue }
            ids.removeAll { $0 == id }
            keyed[key] = ids.isEmpty ? nil : ids
        }
    }

    func cancelAll(for key: some Hashable&Sendable) {
        let key = CancellableKey(key: key)
        let cancellables = lock {
            // Close a one-shot context in the SAME critical section that takes the
            // snapshot, so a concurrent registration under it either lands in this
            // snapshot or sees it closed — never neither.
            key.contextToken?.markCancelled()
            return (keyed.removeValue(forKey: key) ?? []).compactMap { id in
                unfile(id)
                return registered.removeValue(forKey: id)
            }
        }
        threadLocals.withValue(true, at: \.isDrainingCancellations) {
            cancellables.forEach {
                $0.onCancel()
            }
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

    func cancelAll() {
        let cancellables = lock {
            defer {
                registered.removeAll()
                keyed.removeAll()
                keysByID.removeAll()
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

/// The key of a one-shot cancellation context: the anonymous `cancellationContext { }`,
/// and the context `node.task` wraps every task in. Unlike a user key, such a context is
/// never reused, so once cancelled it stays cancelled — and a cancellable registered
/// under it AFTER its cancel has run must be cancelled immediately rather than left
/// running with nothing left to cancel it.
///
/// That window is real: a child task is spawned first and keyed into its parent's
/// context afterwards (`inheritCancellationContext()`), so the parent can be cancelled
/// in between — `forEach(cancelPrevious:)` then left its in-flight body running after
/// the subscription was cancelled. `isCancelled` is set and read under the
/// `Cancellations` lock that also guards `keyed`, which makes "register" and "cancel"
/// linearizable per store.
final class ContextToken: Hashable, @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false

    var isCancelled: Bool { lock { _isCancelled } }
    func markCancelled() { lock { _isCancelled = true } }

    static func == (lhs: ContextToken, rhs: ContextToken) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

struct CancellableKey: Hashable, @unchecked Sendable {
    var key: AnyHashable

    var contextToken: ContextToken? { key.base as? ContextToken }

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

    // `FileAndLine` is the default key of memoize, context storage and cancellation
    // contexts, so these run on every such lookup, and on every comparison of a key
    // path holding one. They must not allocate: building the two `String`s was most of
    // the main thread in a 400-segment editor. Equal literals usually share storage, so
    // the pointer check settles most comparisons; otherwise the bytes are compared.

    package static func == (lhs: FileAndLine, rhs: FileAndLine) -> Bool {
        lhs.line == rhs.line && lhs.column == rhs.column
        && lhs.fileID.isSame(as: rhs.fileID)
        && lhs.filePath.isSame(as: rhs.filePath)
    }

    /// Line, column and the paths' lengths: equal values agree on all of them, and two
    /// call sites rarely do (then `==` compares the bytes).
    package func hash(into hasher: inout Hasher) {
        hasher.combine(line)
        hasher.combine(column)
        hasher.combine(fileID.byteCount)
        hasher.combine(filePath.byteCount)
    }
}

private extension StaticString {
    var byteCount: Int {
        hasPointerRepresentation ? utf8CodeUnitCount : description.utf8.count
    }

    func isSame(as other: StaticString) -> Bool {
        guard hasPointerRepresentation, other.hasPointerRepresentation else {
            // A single-scalar literal; never a `#fileID` / `#filePath`.
            return description == other.description
        }
        let count = utf8CodeUnitCount
        guard count == other.utf8CodeUnitCount else { return false }
        return utf8Start == other.utf8Start || memcmp(utf8Start, other.utf8Start, count) == 0
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

