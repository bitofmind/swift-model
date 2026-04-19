import Foundation
import Dependencies

public extension Model {
    /// Anchors and activates the model, retaining the anchor for the lifetime of the model.
    ///
    /// Once a model is anchored, it and any its descendant models will be activated,
    /// and the model's `onActivate()` will be called.
    /// Any new models added to the hierarchy will be activated, and any models removed
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
    /// When called inside a `@Test(.modelTesting)` function, `withAnchor()` automatically
    /// connects the model to the test scope — no `ModelTester` reference is needed.
    ///
    /// - Parameters:
    ///   - dependencies: A closure for overriding dependencies that will be accessed by the model.
    func withAnchor(
        function: String = #function,
        withDependencies dependencies: @escaping (inout ModelDependencies) -> Void = { _ in },
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> Self {
        // When called inside a @Test(.modelTesting) test, auto-connect to the test scope.
        if let slot = _ModelTestingLocals.scope as? _PendingModelTestScope {
            assertInitialState(function: function)
            let fileAndLine = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
            let slotDependencies = slot.dependencies
            let mergedDependencies: (inout ModelDependencies) -> Void = { deps in
                slotDependencies(&deps)
                dependencies(&deps)
            }
            let tester = ModelTester(
                self,
                exhaustivity: slot.initialExhaustivity,
                dependencies: mergedDependencies,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
            let concrete = _ConcreteModelTestScope(tester: tester)
            slot.register(concrete, at: fileAndLine)
            return tester.model
        }
        let (model, anchor) = returningAnchor(function: function, withDependencies: dependencies)
        model.access!.retainedObject = anchor
        return model
    }

    /// Anchors and activates the model, returning the anchor separately for explicit lifetime control.
    ///
    /// Use `returningAnchor()` when you need to control the anchor's lifetime independently — the
    /// model hierarchy stays alive as long as you hold the returned `ModelAnchor`.
    ///
    ///     let (model, anchor) = AppModel().returningAnchor()
    ///     AppView(model: model)
    ///
    /// Or if you need to override some dependencies:
    ///
    ///     let (model, anchor) = AppModel().returningAnchor {
    ///        $0.uuid = .incrementing
    ///        $0.locale = Locale(identifier: "en_US")
    ///     }
    ///
    /// - Parameters:
    ///   - dependencies: A closure for overriding dependencies that will be accessed by the model.
    func returningAnchor(function: String = #function, withDependencies dependencies: @escaping (inout ModelDependencies) -> Void = { _ in }) -> (model: Self, anchor: ModelAnchor<Self>) {
        assertInitialState(function: function)
        let context = Context(model: self, lock: NSRecursiveLock(), dependencies: dependencies, parent: nil)
        var model = self
        model.withContextAdded(context: context)
        // Call onActivate() directly on the context rather than traversing via activate()
        // on context.model. Context.onActivate() uses allChildren directly and invokes
        // pendingActivation for the model's own onActivate() with correct let values.
        _ = context.onActivate()
        model.modelContext = ModelContext(context: context)
        model.modelContext.access = self.access ?? ModelAccess(useWeakReference: false)
        return (model, ModelAnchor(context: context))
    }

    /// Deprecated: use `returningAnchor(withDependencies:)` instead.
    @available(*, deprecated, renamed: "returningAnchor(withDependencies:)")
    func andAnchor(function: String = #function, andDependencies dependencies: @escaping (inout ModelDependencies) -> Void = { _ in }) -> (model: Self, anchor: ModelAnchor<Self>) {
        returningAnchor(function: function, withDependencies: dependencies)
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
