import Foundation

struct EmptyCancellable: Cancellable {
    func cancel() {}

    func cancel(for key: some Hashable & Sendable, cancelInFlight: Bool) -> EmptyCancellable { self }
}


final class AnyCancellable: Cancellable, InternalCancellable, @unchecked Sendable {
    weak var cancellations: Cancellations?
    let id: Int
    private let _onCancel: @Sendable () -> Void

    init(cancellations: Cancellations, onCancel: @escaping @Sendable () -> Void) {
        self.cancellations = cancellations
        id = cancellations.nextId
        _onCancel = onCancel
        cancellations.register(self)
    }

    func onCancel() {
        _onCancel()
    }

    public func cancel() {
        cancellations?.cancel(self)
    }

    @discardableResult
    public func cancel(for key: some Hashable&Sendable, cancelInFlight: Bool) -> Self {
        cancellations?.cancel(self, for: key, cancelInFlight: cancelInFlight)
        return self
    }

    @TaskLocal static var contexts: [CancellableKey] = []
    @TaskLocal static var inheritedContexts: [CancellableKey] = []
}

final class TaskCancellable: Cancellable, InternalCancellable, @unchecked Sendable {
    let id: Int
    weak var cancellations: Cancellations?
    var task: Task<Void, Error>!
    let name: String
    let fileAndLine: FileAndLine
    let lock = NSLock()
    var hasBeenCancelled = false

    init(name: String, fileAndLine: FileAndLine, context: AnyContext, task: @escaping @Sendable (@escaping @Sendable () -> Void) -> Task<Void, Error>) {
        self.cancellations = context.cancellations
        let id = context.cancellations.nextId
        self.id = id
        self.name = name
        self.fileAndLine = fileAndLine
        self.task = nil

        context.cancellations.register(self)

        lock {
            guard !self.hasBeenCancelled else { return }
            self.task = task { [weak cancellations = context.cancellations] in
                _ = cancellations?.unregister(id)
            }
        }
    }

    func onCancel() {
        lock {
            self.hasBeenCancelled = true
            return self.task
        }?.cancel()
    }

    public func cancel() {
        cancellations?.cancel(self)
    }

    @discardableResult
    public func cancel(for key: some Hashable&Sendable, cancelInFlight: Bool) -> Self {
        cancellations?.cancel(self, for: key, cancelInFlight: cancelInFlight)
        return self
    }
}

extension TaskCancellable {
    convenience init(name: String, fileAndLine: FileAndLine, context: AnyContext, isDetached: Bool, priority: TaskPriority?, @_inheritActorContext @_implicitSelfCapture operation: @escaping @Sendable () async throws -> Void, `catch`: (@Sendable (Error) -> Void)?) {
        self.init(name: name, fileAndLine: fileAndLine, context: context) { onDone in
            let contexts = AnyCancellable.contexts
            let operation = { @Sendable in
                do {
                    try await ModelAccess.$isInModelTaskContext.withValue(true) {
                        try await AnyCancellable.$inheritedContexts.withValue(contexts) {
                            try await AnyCancellable.$contexts.withValue([]) {
                                defer { onDone() }

                                guard !Task.isCancelled, !context.isDestructed else { return }
                                try await operation()
                            }
                        }
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError { return }
                    `catch`?(error)
                }
            }
            
            if isDetached {
                return Task.detached(priority: priority, operation: operation)
            } else {
                return Task(priority: priority, operation: operation)
            }
        }
    }
}

