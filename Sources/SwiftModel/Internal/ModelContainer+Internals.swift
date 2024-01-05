import Foundation

extension ModelContainer {
    func visit<V: ModelVisitor>(with visitor: inout V, includeSelf: Bool) where V.State == Self {
        var containerVisitor = ContainerVisitor(modelVisitor: visitor)
        if includeSelf {
            containerVisitor.visitDynamically(with: self, at: \.self)
        } else {
            visit(with: &containerVisitor)
        }

        //visitor = containerVisitor.modelVisitor as! V
        iOS15Workaround(&visitor, containerVisitor.modelVisitor)
    }

    func iOS15Workaround<V: ModelVisitor>(_ visitor: inout V, _ cont: some ModelVisitor<Self>) where V.State == Self {
        visitor = cont as! V
    }

    var frozenCopy: Self {
        transformModel(with: FrozenCopyTransformer())
    }

    var initialCopy: Self {
        transformModel(with: MakeInitialTransformer())
    }

    func reduceValue<Reducer: ValueReducer>(with reducer: Reducer.Type, initialValue: Reducer.Value) -> Reducer.Value {
        var visitor = ReduceValueVisitor(root: self, path: \.self, reducer: reducer, value: initialValue)
        visit(with: &visitor, includeSelf: true)
        return visitor.value
    }

    func transformModel<Transformer: ModelTransformer>(with transformer: Transformer) -> Self {
        var visitor = ModelTransformerVisitor(root: self, path: \.self, transformer: transformer)
        visit(with: &visitor, includeSelf: true)
        return visitor.root
    }

    var isAllInitial: Bool {
        reduceValue(with: InitialReducer.self, initialValue: true)
    }

    func withDeepAccess(_ access: ModelAccess?) -> Self {
        transformModel(with: WithAccessTransformer(access: access))
    }
}

private struct MakeInitialTransformer: ModelTransformer {
    func transform<M: Model>(_ model: inout M) -> Void {
        model = model.shallowCopy
        model._$modelContext.source = .initial(.init(id: model.modelID))
    }
}

private struct FrozenCopyTransformer: ModelTransformer {
    func transform<M: Model>(_ model: inout M) -> Void {
        model = model.shallowCopy.noAccess
        model._$modelContext.source = .frozenCopy(model.modelID)
    }
}

private struct WithAccessTransformer: ModelTransformer {
    let access: ModelAccess?
    func transform<M: Model>(_ model: inout M) -> Void {
        model._$modelContext.access = access
    }
}

private struct InitialReducer: ValueReducer {
    static func reduce<M: Model>(value: inout Bool, model: M) -> Void {
        value = value && model.isInitial
    }
}

func copy<T>(_ value: T, shouldFreeze: Bool) -> T {
    if shouldFreeze, let models = value as? any ModelContainer {
        return models.frozenCopy as! T
    } else {
        return value
    }
}

func frozenCopy<T>(_ value: T) -> T {
    copy(value, shouldFreeze: true)
}

class ContainerCursor<ID: Hashable, Root, Value>: Hashable, @unchecked Sendable {
    let id: ID
    let get: (Root) -> Value
    let set: (inout Root, Value) -> Void

    init(id: ID, get: @escaping @Sendable (Root) -> Value, set: @escaping @Sendable (inout Root, Value) -> Void) {
        self.id = id
        self.get = get
        self.set = set
    }

    static func == (lhs: ContainerCursor, rhs: ContainerCursor) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension ModelContainer {
    subscript<ID: Hashable, Value> (cursor cursor: ContainerCursor<ID, Self, Value>) -> Value {
        get {
            ModelAccess.$forceDirectAccess.withValue(true) {
                cursor.get(self)
            }
        }
        set {
            ModelAccess.$forceDirectAccess.withValue(true) {
                cursor.set(&self, newValue)
            }
        }
    }
}

struct CaseAndID<ID: Hashable>: Hashable {
    var caseName: String
    var id: ID
}

func anyHashable(from value: Any) -> AnyHashable {
    (value as? any Identifiable)?.anyHashable ?? AnyHashable(ObjectIdentifier(Any.self))
}

extension Identifiable {
    var anyHashable: AnyHashable { AnyHashable(id) }
}

protocol OptionalModel { }

extension Optional: OptionalModel where Wrapped: Model {}

