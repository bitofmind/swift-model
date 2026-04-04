import Testing

// SwiftModelMacros is a host-only macro target; it is not compiled for cross-compilation
// targets like Android. Guard everything else so the target compiles as an empty stub there.
#if canImport(SwiftModelMacros)
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import SwiftModelMacros
import Dependencies
import MacroTesting

@Suite(.macros([
    "Model": ModelMacro.self,
    "_ModelTracked": ModelTrackedMacro.self,
    "_ModelIgnored": ModelIgnoredMacro.self,
    "ModelDependency": ModelDependencyMacro.self,
], record: .never))
struct ModelMacroTests {
    @Test func testClass() {
        assertMacro {
            """
            @Model class MyModel {
                var count = 0
            }
            """
        } diagnostics: {
            """
            @Model class MyModel {
            ┬─────
            ╰─ 🛑 Requires type to be struct
                var count = 0
            }
            """
        }
    }

    @Test func testEnum() {
        assertMacro {
            """
            @Model enum MyModel {
                case count(Int)
            }
            """
        } diagnostics: {
            """
            @Model enum MyModel {
            ┬─────
            ╰─ 🛑 Requires type to be struct
                case count(Int)
            }
            """
        }
    }

    @Test func testModelMacro() {
        assertMacro {
            """
            @Model struct MyModel {
                var count = 0
            }
            """
        } expansion: {
            #"""
            struct MyModel {
                var count = 0 {
                    @storageRestrictions(initializes: _count)
                    init {
                        _count = newValue
                    }
                    _read {
                        yield _$modelContext[model: self, path: \._count]
                    }
                    nonmutating _modify {
                        yield &_$modelContext[model: self, path: \._count]
                    }
                }

                public func visit(with visitor: inout ContainerVisitor<Self>) {
                    visitor.visitStatically(at: \._count)
                }

                var _$contextInit: ModelContext<Self> = ModelContext<Self>()
                {
                    @storageRestrictions(initializes: _$modelContext)
                    init(initialValue) {
                        _$modelContext = initialValue
                    }
                    get {
                        fatalError("_$contextInit is an initializer-only property and must never be read")
                    }
                    set {
                        fatalError("_$contextInit is an initializer-only property and must never be written after initialization")
                    }
                }

                public var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                private var _$modelContext: ModelContext<Self>

                public mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelContext = update._$modelContext
                }
            }

            extension MyModel: SwiftModel.Model {
            }

            extension MyModel: @unchecked Sendable {
            }

            extension MyModel: Identifiable {
            }

            extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("count", count as Any)])
                }
            }

            @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
            extension MyModel: Observation.Observable {
            }

            extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
                public var description: String {
                    node.description(of: self)
                }
                public var debugDescription: String {
                    description
                }
            }
            """#
        }
    }

    @Test func testEquatableAndHashableModel() {
        assertMacro {
            """
            @Model struct MyModel: Hashable {
                var count = 0
            }
            """
        } expansion: {
            #"""
            struct MyModel: Hashable {
                var count = 0 {
                    @storageRestrictions(initializes: _count)
                    init {
                        _count = newValue
                    }
                    _read {
                        yield _$modelContext[model: self, path: \._count]
                    }
                    nonmutating _modify {
                        yield &_$modelContext[model: self, path: \._count]
                    }
                }

                public func visit(with visitor: inout ContainerVisitor<Self>) {
                    visitor.visitStatically(at: \._count)
                }

                public static func ==(_ lhs: Self, _ rhs: Self) -> Bool {
                    lhs.count == rhs.count
                }

                func hash(into hasher: inout Hasher) {
                    hasher.combine(count)
                }

                var _$contextInit: ModelContext<Self> = ModelContext<Self>()
                {
                    @storageRestrictions(initializes: _$modelContext)
                    init(initialValue) {
                        _$modelContext = initialValue
                    }
                    get {
                        fatalError("_$contextInit is an initializer-only property and must never be read")
                    }
                    set {
                        fatalError("_$contextInit is an initializer-only property and must never be written after initialization")
                    }
                }

                public var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                private var _$modelContext: ModelContext<Self>

                public mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelContext = update._$modelContext
                }
            }

            extension MyModel: SwiftModel.Model {
            }

            extension MyModel: @unchecked Sendable {
            }

            extension MyModel: Identifiable {
            }

            extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("count", count as Any)])
                }
            }

            @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
            extension MyModel: Observation.Observable {
            }

            extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
                public var description: String {
                    node.description(of: self)
                }
                public var debugDescription: String {
                    description
                }
            }
            """#
        }
    }

    @Test func testModelWillDidSet() {
        assertMacro {
            """
            @Model struct MyModel {
                let id = 4711

                var count = 0 {
                    willSet { print("willSet") }
                    didSet { print("didSet") }
                }

                var computed: Int { 4711 }
                var computedGet: Int { get { 4711 } }
            }
            """
        } expansion: {
            #"""
            struct MyModel {
                let id = 4711

                var count {
                    willSet { print("willSet") }
                    didSet { print("didSet") }
                    @storageRestrictions(initializes: _count)
                    init {
                        _count = newValue
                    }

                    _read {
                        yield _$modelContext[model: self, path: \._count]
                    }

                    nonmutating set {
                        let oldValue = _$modelContext[model: self, path: \._count]
                        _ = oldValue
                        print("willSet")
                        _$modelContext[model: self, path: \._count] = newValue
                        print("didSet")
                    }
                }

                var computed: Int { 4711 }
                var computedGet: Int { get { 4711 } }

                public func visit(with visitor: inout ContainerVisitor<Self>) {
                    visitor.visitStatically(at: \.id)
                    visitor.visitStatically(at: \._count)
                }

                var _$contextInit: ModelContext<Self> = ModelContext<Self>()
                {
                    @storageRestrictions(initializes: _$modelContext)
                    init(initialValue) {
                        _$modelContext = initialValue
                    }
                    get {
                        fatalError("_$contextInit is an initializer-only property and must never be read")
                    }
                    set {
                        fatalError("_$contextInit is an initializer-only property and must never be written after initialization")
                    }
                }

                public var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                private var _$modelContext: ModelContext<Self>

                public mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelContext = update._$modelContext
                }
            }

            extension MyModel: SwiftModel.Model {
            }

            extension MyModel: @unchecked Sendable {
            }

            extension MyModel: Identifiable {
            }

            extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("id", id as Any), ("count", count as Any)])
                }
            }

            @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
            extension MyModel: Observation.Observable {
            }

            extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
                public var description: String {
                    node.description(of: self)
                }
                public var debugDescription: String {
                    description
                }
            }
            """#
        }
    }

    @Test func testModelPrivateSet() {
        assertMacro {
            """
            @Model struct MyModel {
                private(set) var count = 0
            }
            """
        } expansion: {
            #"""
            struct MyModel {
                private(set) var count = 0 {
                    @storageRestrictions(initializes: _count)
                    init {
                        _count = newValue
                    }
                    _read {
                        yield _$modelContext[model: self, path: \._count]
                    }
                    nonmutating _modify {
                        yield &_$modelContext[model: self, path: \._count]
                    }
                }

                public func visit(with visitor: inout ContainerVisitor<Self>) {
                    visitor.visitStatically(at: \._count)
                }

                var _$contextInit: ModelContext<Self> = ModelContext<Self>()
                {
                    @storageRestrictions(initializes: _$modelContext)
                    init(initialValue) {
                        _$modelContext = initialValue
                    }
                    get {
                        fatalError("_$contextInit is an initializer-only property and must never be read")
                    }
                    set {
                        fatalError("_$contextInit is an initializer-only property and must never be written after initialization")
                    }
                }

                public var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                private var _$modelContext: ModelContext<Self>

                public mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelContext = update._$modelContext
                }
            }

            extension MyModel: SwiftModel.Model {
            }

            extension MyModel: @unchecked Sendable {
            }

            extension MyModel: Identifiable {
            }

            extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("count", count as Any)])
                }
            }

            @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
            extension MyModel: Observation.Observable {
            }

            extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
                public var description: String {
                    node.description(of: self)
                }
                public var debugDescription: String {
                    description
                }
            }
            """#
        }
    }

    @Test func testModelPrivateProperty() {
        assertMacro {
            """
            @Model struct MyModel {
                private var animating = false
            }
            """
        } expansion: {
            #"""
            struct MyModel {
                private var animating = false {
                    @storageRestrictions(initializes: _animating)
                    init {
                        _animating = newValue
                    }
                    _read {
                        yield _$modelContext[model: self, path: \._animating]
                    }
                    nonmutating _modify {
                        yield &_$modelContext[model: self, path: \._animating]
                    }
                }

                public func visit(with visitor: inout ContainerVisitor<Self>) {
                    visitor.visitStatically(at: \._animating, visibility: .private)
                }

                var _$contextInit: ModelContext<Self> = ModelContext<Self>()
                {
                    @storageRestrictions(initializes: _$modelContext)
                    init(initialValue) {
                        _$modelContext = initialValue
                    }
                    get {
                        fatalError("_$contextInit is an initializer-only property and must never be read")
                    }
                    set {
                        fatalError("_$contextInit is an initializer-only property and must never be written after initialization")
                    }
                }

                public var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                private var _$modelContext: ModelContext<Self>

                public mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelContext = update._$modelContext
                }
            }

            extension MyModel: SwiftModel.Model {
            }

            extension MyModel: @unchecked Sendable {
            }

            extension MyModel: Identifiable {
            }

            extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("animating", animating as Any)])
                }
            }

            @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
            extension MyModel: Observation.Observable {
            }

            extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
                public var description: String {
                    node.description(of: self)
                }
                public var debugDescription: String {
                    description
                }
            }
            """#
        }
    }

    @Test func testModelDependencyOnLetProperty() {
        assertMacro(record: .never) {
            """
            @ModelDependency let foo: SomeModel
            """
        } diagnostics: {
            """
            @ModelDependency let foo: SomeModel
            ┬───────────────
            ╰─ 🛑 @ModelDependency requires a 'var' declaration
            """
        }
    }

    @Test func testModelDependencyOnStaticProperty() {
        assertMacro(record: .never) {
            """
            @ModelDependency static var foo: SomeModel
            """
        } diagnostics: {
            """
            @ModelDependency static var foo: SomeModel
            ┬───────────────
            ╰─ 🛑 @ModelDependency cannot be applied to static properties
            """
        }
    }

    @Test func testModelDependencyOnComputedProperty() {
        assertMacro(record: .never) {
            """
            @ModelDependency var computed: Int { 4711 }
            """
        } diagnostics: {
            """
            @ModelDependency var computed: Int { 4711 }
            ┬───────────────
            ╰─ 🛑 @ModelDependency cannot be applied to computed properties
            """
        }
    }

    @Test func testModelDependencyWithInitializer() {
        assertMacro(record: .never) {
            """
            @ModelDependency var foo: SomeModel = SomeModel()
            """
        } diagnostics: {
            """
            @ModelDependency var foo: SomeModel = SomeModel()
            ┬───────────────
            ╰─ ⚠️ Initial value of a @ModelDependency property is ignored; the value is resolved from the dependency container
            """
        } expansion: {
            """
            var foo: SomeModel {
                get {
                    _$modelContext.dependency()
                }
            }
            """
        }
    }

    @Test func testModelIgnoredOnComputedProperty() {
        assertMacro(record: .never) {
            """
            @_ModelIgnored var computed: Int { 4711 }
            """
        } diagnostics: {
            """
            @_ModelIgnored var computed: Int { 4711 }
            ┬─────────────
            ╰─ ⚠️ @ModelIgnored has no effect on computed properties
            """
        } expansion: {
            """
            var computed: Int { 4711 }
            """
        }
    }

    @Test func testModelDependencyWithKeyPath() {
        assertMacro(record: .never) {
            """
            @ModelDependency(\\.clock) var clock: ContinuousClock
            """
        } expansion: {
            """
            var clock: ContinuousClock {
                get {
                    _$modelContext.dependency(for: \\.clock)
                }
            }
            """
        }
    }

    @Test func testModelDependency() {
        assertMacro(record: .never) {
            """
            @Model struct MyModel {
                @ModelDependency var someModel: SomeModel
            }
            """
        } expansion: {
            """
            struct MyModel {
                var someModel: SomeModel {
                    get {
                        _$modelContext.dependency()
                    }
                }

                public func visit(with visitor: inout ContainerVisitor<Self>) {

                }

                var _$contextInit: ModelContext<Self> = ModelContext<Self>()
                {
                    @storageRestrictions(initializes: _$modelContext)
                    init(initialValue) {
                        _$modelContext = initialValue
                    }
                    get {
                        fatalError("_$contextInit is an initializer-only property and must never be read")
                    }
                    set {
                        fatalError("_$contextInit is an initializer-only property and must never be written after initialization")
                    }
                }

                public var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                private var _$modelContext: ModelContext<Self>

                public mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelContext = update._$modelContext
                }
            }

            extension MyModel: SwiftModel.Model {
            }

            extension MyModel: @unchecked Sendable {
            }

            extension MyModel: Identifiable {
            }

            extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [])
                }
            }

            @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
            extension MyModel: Observation.Observable {
            }

            extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
                public var description: String {
                    node.description(of: self)
                }
                public var debugDescription: String {
                    description
                }
            }
            """
        }
    }
}

#endif // canImport(SwiftModelMacros)
