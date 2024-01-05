import XCTestDynamicOverlay

/// Helper used by `ModelContainer`'s visit to implement
public struct ContainerVisitor<State> {
    var modelVisitor: any ModelVisitor<State>
}

public extension ContainerVisitor {
    /// If we can't know statically what type type we will visit, use `visitDynamically`.
    /// E.g. if you have generic container, we don't know statically the elements type in a generic implementation.
    mutating func visitDynamically<T>(with value: T, at path: WritableKeyPath<State, T>) {
        if let model = value as? any Model, !(value is OptionalModel) {
            visit(model: model, path: path)
        } else if let container = value as? any ModelContainer {
            visit(container: container, path: path)
        } else {
            modelVisitor.visit(path: path)
        }
    }
}

public extension ContainerVisitor {
    mutating func visitStatically<T>(at path: WritableKeyPath<State, T>) {
        modelVisitor.visit(path: path)
    }

    mutating func visitStatically<T: Model>(at path: WritableKeyPath<State, T>) {
        modelVisitor.visit(path: path)
    }

    mutating func visitStatically<T: ModelContainer>(at path: WritableKeyPath<State, T>) {
        modelVisitor.visit(path: path)
    }

    mutating func visitStatically<T: ModelContainer&Sequence>(at path: WritableKeyPath<State, T>) {
        modelVisitor.visit(path: path)
    }

    mutating func visitStatically<T: Sequence>(at path: WritableKeyPath<State, T>) where T.Element: Model {
        XCTFail("Collection of models needs to conform to ModelContainer")
        modelVisitor.visit(path: path)
    }

    mutating func visitStatically<M: ModelContainer>(at path: KeyPath<State, M>) {
        XCTFail("Model(Container) of type \(M.self) declared in \(State.self) can't be declared as a let.")
    }

    mutating func visitStatically<T>(at path: KeyPath<State, T>) { }
}

private extension ContainerVisitor {
    mutating func visit<M: Model, T>(model: M, path: WritableKeyPath<State, T>) {
        modelVisitor.visit(path: path as! WritableKeyPath<State, M>)
    }

    mutating func visit<M: ModelContainer, T>(container: M, path: WritableKeyPath<State, T>) {
        modelVisitor.visit(path: path as! WritableKeyPath<State, M>)
    }
}
