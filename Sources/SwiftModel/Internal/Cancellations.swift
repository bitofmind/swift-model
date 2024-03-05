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

    var activeTasks: [(modelName: String, fileAndLines: [FileAndLine])] {
        lock {
            registered.values.reduce(into: [String: [FileAndLine]]()) { dict, c in
                if let task = c as? TaskCancellable {
                    dict[task.name, default: []].append(task.fileAndLine)
                }
            }.map { (modelName: $0.key, fileAndLines: $0.value) }
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
}

struct FileAndLine: Hashable, Sendable {
    var file: StaticString
    var line: UInt

    static func == (lhs: FileAndLine, rhs: FileAndLine) -> Bool {
        lhs.line == rhs.line && lhs.file.description == rhs.file.description
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(file.description)
        hasher.combine(line)
    }
}
