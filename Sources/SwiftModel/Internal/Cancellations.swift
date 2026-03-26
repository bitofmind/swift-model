import Foundation

final class Cancellations: @unchecked Sendable {
    fileprivate let lock = NSLock()
    fileprivate var registered: [Int: InternalCancellable] = [:]
    fileprivate var keyed: [CancellableKey: [Int]] = [:]

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

    func register(_ c: InternalCancellable) {
        lock {
            registered[c.id] = c

            for key in AnyCancellable.contexts {
                keyed[key, default: []].append(c.id)
            }
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

