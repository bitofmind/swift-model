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
    /// - Parameters:
    ///   - dependencies: A closure for overriding dependencies that will be accessed by the model
    func withAnchor(function: String = #function, andDependencies dependencies: @escaping (inout ModelDependencies) -> Void = { _ in }) -> Self {
        let (model, anchor) = andAnchor(options: [], function: function, andDependencies: dependencies)

        // Hold on to anchor as long as model's access object is alive.
        model.access!.retainedObject = anchor

        return model
    }

    /// An anchor keeps a model hierarchy active.
    ///
    /// Once a model is anchored, it and any its descendant models will be activated,
    /// and the model's `onActivate()` will be called.
    /// Any new models added to the hierarchy will activated, and any models removed
    /// will be deactivated.
    ///
    /// Use `andAnchor()` when you need to hold on to the anchor separately:
    ///
    ///     let (model, anchor) = AppModel().andAnchor()
    ///     AppView(model: model)
    ///
    /// Or if you need to override some dependencies:
    ///
    ///     let (model, anchor) = AppModel().andAnchor {
    ///        $0.uuid = .incrementing
    ///        $0.locale = Locale(identifier: "en_US")
    ///     }
    ///
    /// - Parameters:
    ///   - dependencies: A closure for overriding dependencies that will be accessed by the model.
    func andAnchor(function: String = #function, andDependencies dependencies: @escaping (inout ModelDependencies) -> Void = { _ in }) -> (model: Self, anchor: ModelAnchor<Self>) {
        assertInitialState(function: function)

        let context = Context(model: self, lock: NSRecursiveLock(), options: [], dependencies: dependencies, parent: nil)

        var model = self
        model.withContextAdded(context: context)
        context.model.activate()

        model.modelContext = ModelContext(context: context)
        model.modelContext.access = self.access ?? ModelAccess(useWeakReference: false)

        return (model, ModelAnchor(context: context))
    }
}

// Internal overloads used by tests (via @testable import) to exercise specific option combinations.
extension Model {
    func withAnchor(options: ModelOption, function: String = #function, andDependencies dependencies: @escaping (inout ModelDependencies) -> Void = { _ in }) -> Self {
        let (model, anchor) = andAnchor(options: options, function: function, andDependencies: dependencies)
        model.access!.retainedObject = anchor
        return model
    }

    func andAnchor(options: ModelOption, function: String = #function, andDependencies dependencies: @escaping (inout ModelDependencies) -> Void = { _ in }) -> (model: Self, anchor: ModelAnchor<Self>) {
        assertInitialState(function: function)
        let context = Context(model: self, lock: NSRecursiveLock(), options: options, dependencies: dependencies, parent: nil)
        var model = self
        model.withContextAdded(context: context)
        context.model.activate()
        model.modelContext = ModelContext(context: context)
        model.modelContext.access = self.access ?? ModelAccess(useWeakReference: false)
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
