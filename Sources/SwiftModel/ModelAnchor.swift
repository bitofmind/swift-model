import Foundation
import Dependencies

public extension Model {
    /// An anchor keeps a model hierarchy active.
    ///
    /// Once a model is anchored, it and any its descendant models will be activated,
    /// and the model's `onActivate()` will be called.
    /// Any new models added to the hierarchy will activated, and any models removed
    /// will be deactivated.
    ///
    ///     AppView(model: AppModel().withAnchor())
    ///
    /// Or if you need to override some dependencies:
    ///
    ///     AppView(model: AppModel().withAnchor {
    ///        $0.uuid = .incrementing
    ///        $0.locale = Locale(identifier: "en_US")
    ///     })
    ///
    /// - Parameter dependencies: A closure for to overriding dependencies that will be accessed by the model
    func withAnchor(function: String = #function, andDependencies dependencies: @escaping (inout ModelDependencies) -> Void = { _ in }) -> Self {
        let (model, anchor) = andAnchor(function: function, andDependencies: dependencies)
       
        // Hold on to anchor as long as model is alive.
        objc_setAssociatedObject(model.access!.reference, &anchorKey, anchor, .OBJC_ASSOCIATION_RETAIN)

        return model
    }

    /// An anchor keeps a model hierarchy active.
    ///
    /// Once a model is anchored, it and any its descendant models will be activated,
    /// and the model's `onActivate()` will be called.
    /// Any new models added to the hierarchy will activated, and any models removed
    /// will be deactivated.
    ///
    ///     struct MyApp: App {
    ///     AppView(model: )
    ///
    /// Or if you need to override some dependencies:
    ///
    ///     AppView(model: AppModel().withAnchor {
    ///        $0.uuid = .incrementing
    ///        $0.locale = Locale(identifier: "en_US")
    ///     })
    ///
    /// - Parameter dependencies: A closure for to overriding dependencies that will be accessed by the model
    func andAnchor(function: String = #function, andDependencies dependencies: @escaping (inout ModelDependencies) -> Void = { _ in }) -> (model: Self, anchor: ModelAnchor<Self>) {
        assertInitialState(function: function)

        let context = Context(model: self, lock: NSRecursiveLock(), dependencies: dependencies, parent: nil)

        var model = self
        model.withContextAdded(context: context)
        context.model.activate()

        model._$modelContext = ModelContext(context: context)
        let access = self.access ?? ModelAccess(useWeakReference: false)
        model._$modelContext.access = access

        return (model, ModelAnchor(context: context))
    }
}

public class ModelAnchor<M: Model>: @unchecked Sendable {
    fileprivate var context: Context<M>

    fileprivate init(context: Context<M>) {
        self.context = context
    }

    deinit {
        context.onRemoval()
    }
}

private nonisolated(unsafe) var anchorKey: Void?
