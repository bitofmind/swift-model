import Foundation

#if canImport(Combine)
@preconcurrency import Combine

public extension ModelNode {
    /// Receive updates from a publisher for the life time of the model
    ///
    /// - Parameter catch: Called if the sequence throws an error
    /// - Returns: A cancellable to optionally allow cancelling before a view goes away
    @discardableResult
    func onReceive<P: Publisher>(_ publisher: P, perform: @escaping (P.Output) -> Void, `catch`: ((Error) -> Void)? = nil) -> Cancellable {
        let cancellable = publisher.sink(receiveCompletion: { completion in
            if case let .failure(error) = completion {
                `catch`?(error)
            }
        }, receiveValue: { value in
            perform(value)
        })

        return onCancel {
            cancellable.cancel()
        }
    }
}

#endif
