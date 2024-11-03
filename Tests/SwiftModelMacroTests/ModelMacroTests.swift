import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest
import SwiftModelMacros
import Dependencies
import MacroTesting

final class ModelMacroTests: XCTestCase {
    override func invokeTest() {
        withMacroTesting(record: false, macros: [
            "Model": ModelMacro.self,
            "ModelTracked": ModelTrackedMacro.self,
            "ModelIgnored": ModelIgnoredMacro.self,
            "ModelDependency": ModelDependencyMacro.self,
        ]) {
            super.invokeTest()
        }
    }

    func testClass() {
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

    func testEnum() {
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

    func testModelMacro() {
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

                public var _$modelContext: ModelContext<Self> = ModelContext<Self>()
                {
                    @storageRestrictions(initializes: _node)
                    init {
                        _node = ModelNode(_$modelContext: newValue)
                    }
                    get {
                        _node._$modelContext
                    }
                    set {
                        _node = ModelNode(_$modelContext: newValue)
                    }
                }

                private var _node = ModelNode(_$modelContext: ModelContext<Self>())

                private var node: ModelNode<Self> {
                    _node
                }
            }

            extension MyModel: SwiftModel.Model {
            }

            extension MyModel: Sendable {
            }

            extension MyModel: Identifiable {
            }

            extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    _$modelContext.mirror(of: self, children: [("count", count as Any)])
                }
            }

            @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
            extension MyModel: Observation.Observable {
            }

            extension MyModel: CustomStringConvertible {
                public var description: String {
                    _$modelContext.description(of: self)
                }
            }
            """#
        }
    }

    func testEquatableAndHashableModel() {
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

                public static func == (_ lhs: Self, _ rhs: Self) -> Bool {
                    lhs.count == rhs.count
                }

                func hash(into hasher: inout Hasher) {
                    hasher.combine(count)
                }

                public var _$modelContext: ModelContext<Self> = ModelContext<Self>()
                {
                    @storageRestrictions(initializes: _node)
                    init {
                        _node = ModelNode(_$modelContext: newValue)
                    }
                    get {
                        _node._$modelContext
                    }
                    set {
                        _node = ModelNode(_$modelContext: newValue)
                    }
                }

                private var _node = ModelNode(_$modelContext: ModelContext<Self>())

                private var node: ModelNode<Self> {
                    _node
                }
            }

            extension MyModel: SwiftModel.Model {
            }

            extension MyModel: Sendable {
            }

            extension MyModel: Identifiable {
            }

            extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    _$modelContext.mirror(of: self, children: [("count", count as Any)])
                }
            }

            @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
            extension MyModel: Observation.Observable {
            }

            extension MyModel: CustomStringConvertible {
                public var description: String {
                    _$modelContext.description(of: self)
                }
            }
            """#
        }
    }

    func testModelWillDidSet() {
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

                var count = 0 {
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

                public var _$modelContext: ModelContext<Self> = ModelContext<Self>()
                {
                    @storageRestrictions(initializes: _node)
                    init {
                        _node = ModelNode(_$modelContext: newValue)
                    }
                    get {
                        _node._$modelContext
                    }
                    set {
                        _node = ModelNode(_$modelContext: newValue)
                    }
                }

                private var _node = ModelNode(_$modelContext: ModelContext<Self>())

                private var node: ModelNode<Self> {
                    _node
                }
            }

            extension MyModel: SwiftModel.Model {
            }

            extension MyModel: Sendable {
            }

            extension MyModel: Identifiable {
            }

            extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    _$modelContext.mirror(of: self, children: [("id", id as Any), ("count", count as Any)])
                }
            }

            @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
            extension MyModel: Observation.Observable {
            }

            extension MyModel: CustomStringConvertible {
                public var description: String {
                    _$modelContext.description(of: self)
                }
            }
            """#
        }
    }

    func testModelPrivateSet() {
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

                public var _$modelContext: ModelContext<Self> = ModelContext<Self>()
                {
                    @storageRestrictions(initializes: _node)
                    init {
                        _node = ModelNode(_$modelContext: newValue)
                    }
                    get {
                        _node._$modelContext
                    }
                    set {
                        _node = ModelNode(_$modelContext: newValue)
                    }
                }

                private var _node = ModelNode(_$modelContext: ModelContext<Self>())

                private var node: ModelNode<Self> {
                    _node
                }
            }

            extension MyModel: SwiftModel.Model {
            }

            extension MyModel: Sendable {
            }

            extension MyModel: Identifiable {
            }

            extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    _$modelContext.mirror(of: self, children: [("count", count as Any)])
                }
            }

            @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
            extension MyModel: Observation.Observable {
            }

            extension MyModel: CustomStringConvertible {
                public var description: String {
                    _$modelContext.description(of: self)
                }
            }
            """#
        }
    }

    func testModelDependency() {
        assertMacro(record: false) {
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

                public var _$modelContext: ModelContext<Self> = ModelContext<Self>()
                {
                    @storageRestrictions(initializes: _node)
                    init {
                        _node = ModelNode(_$modelContext: newValue)
                    }
                    get {
                        _node._$modelContext
                    }
                    set {
                        _node = ModelNode(_$modelContext: newValue)
                    }
                }

                private var _node = ModelNode(_$modelContext: ModelContext<Self>())

                private var node: ModelNode<Self> {
                    _node
                }
            }

            extension MyModel: SwiftModel.Model {
            }

            extension MyModel: Sendable {
            }

            extension MyModel: Identifiable {
            }

            extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    _$modelContext.mirror(of: self, children: [])
                }
            }

            @available(macOS 14.0, iOS 17.0, watchOS 10.0, tvOS 17.0, *)
            extension MyModel: Observation.Observable {
            }

            extension MyModel: CustomStringConvertible {
                public var description: String {
                    _$modelContext.description(of: self)
                }
            }
            """
        }
    }
}
