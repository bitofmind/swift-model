import Foundation
import Dependencies

extension Model {
    func assertInitialState(function: String = #function) {
        if lifetime != .initial {
            reportIssue("Calling \(function) on an anchored model is not allowed and has no effect")
        }
    }

    func withSetupAccess(modify: (ModelSetupAccess<Self>) -> Void, function: String = #function) -> Self {
        assertInitialState(function: function)

        let access = (access as? ModelSetupAccess<Self>) ?? ModelSetupAccess<Self>()
        modify(access)
        return withAccess(access)
    }

    var modelSetup: ModelSetupAccess<Self>? {
        access as? ModelSetupAccess<Self>
    }
}

final class ModelSetupAccess<M: Model>: ModelAccess, @unchecked Sendable {
    var dependencies: [(inout ModelDependencies) -> Void] = []
    var activations: [(M) -> Void] = []

    var allDependencies: ((inout ModelDependencies) -> Void)? {
        if dependencies.isEmpty { return nil }
        return { [dependencies = dependencies] in
            for dependency in dependencies {
                dependency(&$0)
            }
        }
    }

    init() {
        super.init(useWeakReference: false)
    }
}

extension Model {
    var typeDescription: String {
        String(describing: type(of: self))
    }

    func transaction<T>(_ callback: () throws -> T) rethrows -> T {
        try _$modelContext.transaction(callback)
    }
}

extension Model {
    var noAccess: Self {
        var copy = self
        copy._$modelContext.access = nil
        return copy
    }
    
    var shallowCopy: Self {
        switch _$modelContext.source {
        case .frozenCopy:
            return self
            
        case let .reference(reference):
            if let context = reference.context {
                var copy = context[\.self]
                copy._$modelContext.source = .frozenCopy(id: copy.modelID)
                copy._$modelContext.access = nil
                return copy
            } else if let last = reference.model {
                return last
            } else {
                return self
            }
            
        case let .lastSeen(id: id):
            var copy = self
            copy._$modelContext.source = .frozenCopy(id: id)
            return copy
        }
    }
}

extension Model {
    func enforcedContext(_ function: StaticString = #function) -> Context<Self>? {
        enforcedContext("Calling \(function) on an unanchored model is not allowed and has no effect")
    }

    func enforcedContext(_ message: @autoclosure () -> String) -> Context<Self>? {
        guard let context else {
            reportIssue(message())
            return nil
        }

        return context
    }
}

@available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
extension Model where Self: Observable {
    func access<M: Model, T>(path: KeyPath<M, T>&Sendable, from context: Context<M>) {
        context.observationRegistrar?.access(self, keyPath: path as! KeyPath<Self, T>)
    }

    func willSet<M: Model, T>(path: KeyPath<M, T>&Sendable, from context: Context<M>) {
        if Thread.isMainThread {
            context.observationRegistrar?.willSet(self, keyPath: path as! KeyPath<Self, T>)
        }
    }

    func didSet<M: Model, T>(path: KeyPath<M, T>&Sendable, from context: Context<M>) {
        if Thread.isMainThread {
            context.observationRegistrar?.didSet(self, keyPath: path as! KeyPath<Self, T>)
        } else if let registrar = context.observationRegistrar {
            mainCall { // Make sure to call out on main thread to not upset SwiftUI, as well call willSet after value has been sat to avoid data race where SwiftUI won't detect the change.
                registrar.willSet(self, keyPath: path as! KeyPath<Self, T>)
                registrar.didSet(self, keyPath: path as! KeyPath<Self, T>)
            }
        }
    }
}

// Coalesce calls to main thread.
private struct MainCalls {
    private let calls = LockIsolated<(task: Task<(), Never>, calls: [@Sendable () -> Void])?>(nil)
    func callAsFunction(_ callback: @escaping @Sendable () -> Void) {
        calls.withValue {
            if $0 == nil {
                $0 = (Task { @MainActor in
                    while !Task.isCancelled {
                        let calls: [@Sendable () -> Void] = calls.withValue {
                            if $0 == nil || $0?.calls.isEmpty == true {
                                $0?.task.cancel()
                                $0 = nil
                                return []
                            }

                            let calls = $0?.calls ?? []
                            $0?.calls.removeAll()
                            return calls
                        }

                        for call in calls {
                            call()
                        }

                        await Task.yield()
                    }
                }, calls: [])
            }

            $0?.calls.append(callback)
        }
    }
}

private let mainCall = MainCalls()

