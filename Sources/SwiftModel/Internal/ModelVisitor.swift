import OrderedCollections

protocol ModelVisitor<State> {
    associatedtype State
    mutating func visit<T>(path: KeyPath<State, T>)
    mutating func visit<T>(path: WritableKeyPath<State, T>)
    mutating func visit<T: Model>(path: WritableKeyPath<State, T>)
    mutating func visit<T: ModelContainer>(path: WritableKeyPath<State, T>)
}

extension ModelVisitor {
    mutating func visit<T>(path: KeyPath<State, T>) { }
    mutating func visit<T>(path: WritableKeyPath<State, T>) { }
}

protocol ModelTransformer {
    func transform<M: Model>(_ model: inout M)
}

struct ModelTransformerVisitor<Root, Child, Transformer: ModelTransformer>: ModelVisitor {
    var root: Root
    let path: WritableKeyPath<Root, Child>
    let transformer: Transformer

    mutating func visit<T: Model>(path: WritableKeyPath<Child, T>) {
        let fullPath = self.path.appending(path: path)
        transformer.transform(&root[keyPath: fullPath])

        var visitor = ModelTransformerVisitor<Root, T, Transformer>(root: root, path: fullPath, transformer: transformer)
        root[keyPath: fullPath].visit(with: &visitor, includeSelf: false)
        root = visitor.root
    }

    mutating func visit<T: ModelContainer>(path: WritableKeyPath<Child, T>) {
        let fullPath = self.path.appending(path: path)
        var visitor = ModelTransformerVisitor<Root, T, Transformer>(root: root, path: fullPath, transformer: transformer)
        root[keyPath: fullPath].visit(with: &visitor, includeSelf: false)
        root = visitor.root
    }
}

protocol ValueReducer {
    associatedtype Value
    static func reduce<M: Model>(value: inout Value, model: M) -> Void
}

struct ReduceValueVisitor<Root, Child, Reducer: ValueReducer>: ModelVisitor {
    let root: Root
    let path: WritableKeyPath<Root, Child>
    let reducer: Reducer.Type
    var value: Reducer.Value

    mutating func visit<T: Model>(path: WritableKeyPath<Child, T>) {
        let fullPath = self.path.appending(path: path)
        reducer.reduce(value: &value, model: root[keyPath: fullPath])

        var visitor = ReduceValueVisitor<Root, T, Reducer>(root: root, path: fullPath, reducer: reducer, value: value)
        root[keyPath: fullPath].visit(with: &visitor, includeSelf: false)
        value = visitor.value
    }

    mutating func visit<T: ModelContainer>(path: WritableKeyPath<Child, T>) {
        let fullPath = self.path.appending(path: path)
        var visitor = ReduceValueVisitor<Root, T, Reducer>(root: root, path: fullPath, reducer: reducer, value: value)
        root[keyPath: fullPath].visit(with: &visitor, includeSelf: false)
        value = visitor.value
    }
}

struct AnchorVisitor<M: Model, Container: ModelContainer, Value: ModelContainer>: ModelVisitor {
    var value: Value
    var didAttemptToReplaceWithAnchoredModel = false
    let context: Context<M>
    let containerPath: WritableKeyPath<M, Container>
    let elementPath: WritableKeyPath<Container, Value>

    init(value: Value, context: Context<M>, containerPath: WritableKeyPath<M, Container>, elementPath: WritableKeyPath<Container, Value>) {
        self.value = value
        self.context = context
        self.containerPath = containerPath
        self.elementPath = elementPath
    }

    mutating func visit<T: Model>(path: WritableKeyPath<Value, T>) {
        let childModel = value[keyPath: path]
        let isSelf = self.containerPath == \.self && path == \.self

        let modelElementPath = elementPath.appending(path: path)

        let childContext = isSelf ? (context as! Context<T>) : context.childContext(containerPath: containerPath, elementPath: modelElementPath, childModel: childModel)

        if childContext !== childModel.context {
            if childModel.context != nil {
                ModelLifetime.didReplaceModelWithAnchoredModel()
            }
            value[keyPath: path].withContextAdded(context: childContext, containerPath: \.self, elementPath: \.self, includeSelf: false)
            value[keyPath: path]._$modelContext = ModelContext(context: childContext)
        }
    }

    mutating func visit<T: ModelContainer>(path: WritableKeyPath<Value, T>) {
        if containerPath == \.self, elementPath == \.self {
            value[keyPath: path].withContextAdded(context: context, containerPath: path as! WritableKeyPath<M, T>, elementPath: \.self, includeSelf: false)
        } else {
            value[keyPath: path].withContextAdded(context: context, containerPath: containerPath, elementPath: elementPath.appending(path: path), includeSelf: false)
        }
    }
}
