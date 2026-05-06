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

    /// Basic model with a default-value property (inferred type).
    @Test func testModelBasicProperty() {
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
                    @storageRestrictions(initializes: _$modelAccess, _$modelSource)
                    init(newValue) {
                        _$modelAccess = _ModelAccessBox()
                        _ModelSourceBox<Self>._threadLocalStoreFirst(\.count, newValue)
                        _$modelSource = ._popFromThreadLocal(Self._makeState)
                    }
                    _read {
                        yield _$modelSource[read: \_State.count, access: _$modelAccess]
                    }
                    nonmutating _modify {
                        yield &_$modelSource[write: \_State.count, access: _$modelAccess]
                    }
                }

                public nonisolated func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    visitor.visitStatically(statePath: \.count)
                }

                public nonisolated struct _State: _ModelStateType {
                    var count = 0
                }

                public typealias _ModelState = _State

                private nonisolated static func _makeState(from pending: PendingStorage<_State>) -> _State {
                    _State(count: pending.value(for: \.count, default: 0))
                }

                private nonisolated var _modelState: _State {
                    get {
                        _$modelSource._modelState
                    }
                    nonmutating set {
                        _$modelSource._modelState = newValue
                    }
                }

                private var _$modelAccess: _ModelAccessBox = _ModelAccessBox()

                private var _$modelSource: _ModelSourceBox<Self> = ._popFromThreadLocal(Self._makeState)

                public nonisolated static var _modelStateKeyPath: WritableKeyPath<Self, _State> {
                    \Self._modelState
                }

                private nonisolated var _$modelContext: ModelContext<Self> {
                    get {
                        ModelContext(_access: _$modelAccess, _source: _$modelSource)
                    }
                }

                public nonisolated var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                public nonisolated mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelAccess = update._$modelContext._access
                    _$modelSource = update._$modelContext._source
                }
            }

            nonisolated extension MyModel: SwiftModel.Model {
            }

            nonisolated extension MyModel: @unchecked Sendable {
            }

            nonisolated extension MyModel: Identifiable {
            }

            nonisolated extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("count", count as Any)])
                }
            }

            nonisolated extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
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

    /// Model with an explicit type annotation but no default (requires user init).
    @Test func testModelCustomInit() {
        assertMacro {
            """
            @Model struct MyModel {
                var activateCount: Int

                init(activateCount: Int = 0) {
                    self.activateCount = activateCount
                }
            }
            """
        } expansion: {
            #"""
            struct MyModel {
                var activateCount: Int {
                    @storageRestrictions(initializes: _$modelAccess, _$modelSource)
                    init(newValue) {
                        _$modelAccess = _ModelAccessBox()
                        _ModelSourceBox<Self>._threadLocalStoreFirst(\.activateCount, newValue)
                        _$modelSource = ._popFromThreadLocal(Self._makeState)
                    }
                    _read {
                        yield _$modelSource[read: \_State.activateCount, access: _$modelAccess]
                    }
                    nonmutating _modify {
                        yield &_$modelSource[write: \_State.activateCount, access: _$modelAccess]
                    }
                }

                init(activateCount: Int = 0) {
                    self.activateCount = activateCount
                }

                public nonisolated func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    visitor.visitStatically(statePath: \.activateCount)
                }

                public nonisolated struct _State: _ModelStateType {
                    var activateCount: Int
                }

                public typealias _ModelState = _State

                private nonisolated static func _makeState(from pending: PendingStorage<_State>) -> _State {
                    _State(activateCount: pending.value(for: \.activateCount, default: _zeroInit()))
                }

                private nonisolated var _modelState: _State {
                    get {
                        _$modelSource._modelState
                    }
                    nonmutating set {
                        _$modelSource._modelState = newValue
                    }
                }

                private var _$modelAccess: _ModelAccessBox = _ModelAccessBox()

                private var _$modelSource: _ModelSourceBox<Self> = ._popFromThreadLocal(Self._makeState)

                public nonisolated static var _modelStateKeyPath: WritableKeyPath<Self, _State> {
                    \Self._modelState
                }

                private nonisolated var _$modelContext: ModelContext<Self> {
                    get {
                        ModelContext(_access: _$modelAccess, _source: _$modelSource)
                    }
                }

                public nonisolated var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                public nonisolated mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelAccess = update._$modelContext._access
                    _$modelSource = update._$modelContext._source
                }
            }

            nonisolated extension MyModel: SwiftModel.Model {
            }

            nonisolated extension MyModel: @unchecked Sendable {
            }

            nonisolated extension MyModel: Identifiable {
            }

            nonisolated extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("activateCount", activateCount as Any)])
                }
            }

            nonisolated extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
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

    @Test func testModelEquatableAndHashable() {
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
                    @storageRestrictions(initializes: _$modelAccess, _$modelSource)
                    init(newValue) {
                        _$modelAccess = _ModelAccessBox()
                        _ModelSourceBox<Self>._threadLocalStoreFirst(\.count, newValue)
                        _$modelSource = ._popFromThreadLocal(Self._makeState)
                    }
                    _read {
                        yield _$modelSource[read: \_State.count, access: _$modelAccess]
                    }
                    nonmutating _modify {
                        yield &_$modelSource[write: \_State.count, access: _$modelAccess]
                    }
                }

                public nonisolated func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    visitor.visitStatically(statePath: \.count)
                }

                public nonisolated static func ==(_ lhs: Self, _ rhs: Self) -> Bool {
                    lhs.count == rhs.count
                }

                nonisolated func hash(into hasher: inout Hasher) {
                    hasher.combine(count)
                }

                public nonisolated struct _State: _ModelStateType {
                    var count = 0
                }

                public typealias _ModelState = _State

                private nonisolated static func _makeState(from pending: PendingStorage<_State>) -> _State {
                    _State(count: pending.value(for: \.count, default: 0))
                }

                private nonisolated var _modelState: _State {
                    get {
                        _$modelSource._modelState
                    }
                    nonmutating set {
                        _$modelSource._modelState = newValue
                    }
                }

                private var _$modelAccess: _ModelAccessBox = _ModelAccessBox()

                private var _$modelSource: _ModelSourceBox<Self> = ._popFromThreadLocal(Self._makeState)

                public nonisolated static var _modelStateKeyPath: WritableKeyPath<Self, _State> {
                    \Self._modelState
                }

                private nonisolated var _$modelContext: ModelContext<Self> {
                    get {
                        ModelContext(_access: _$modelAccess, _source: _$modelSource)
                    }
                }

                public nonisolated var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                public nonisolated mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelAccess = update._$modelContext._access
                    _$modelSource = update._$modelContext._source
                }
            }

            nonisolated extension MyModel: SwiftModel.Model {
            }

            nonisolated extension MyModel: @unchecked Sendable {
            }

            nonisolated extension MyModel: Identifiable {
            }

            nonisolated extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("count", count as Any)])
                }
            }

            nonisolated extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
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

    /// Model with `willSet`/`didSet` — verifies observer forwarding in `nonmutating set`.
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
                    @storageRestrictions(initializes: _$modelAccess, _$modelSource)
                    init(newValue) {
                        _$modelAccess = _ModelAccessBox()
                        _ModelSourceBox<Self>._threadLocalStoreFirst(\.count, newValue)
                        _$modelSource = ._popFromThreadLocal(Self._makeState)
                    }

                    _read {
                        yield _$modelSource[read: \_State.count, access: _$modelAccess]
                    }

                    nonmutating set {
                        guard !_$modelSource._storePendingIfNeeded(\.count, newValue) else {
                            return
                        }
                        let oldValue = _$modelSource[read: \_State.count, access: _$modelAccess]
                        _ = oldValue
                        print("willSet")
                        _$modelSource[write: \_State.count, access: _$modelAccess] = newValue
                        print("didSet")
                    }
                }

                var computed: Int { 4711 }
                var computedGet: Int { get { 4711 } }

                public nonisolated func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    visitor.visitStatically(at: \.id)
                    visitor.visitStatically(statePath: \.count)
                }

                public nonisolated struct _State: _ModelStateType {
                    var count = 0
                }

                public typealias _ModelState = _State

                private nonisolated static func _makeState(from pending: PendingStorage<_State>) -> _State {
                    _State(count: pending.value(for: \.count, default: 0))
                }

                private nonisolated var _modelState: _State {
                    get {
                        _$modelSource._modelState
                    }
                    nonmutating set {
                        _$modelSource._modelState = newValue
                    }
                }

                private var _$modelAccess: _ModelAccessBox = _ModelAccessBox()

                private var _$modelSource: _ModelSourceBox<Self> = ._popFromThreadLocal(Self._makeState)

                public nonisolated static var _modelStateKeyPath: WritableKeyPath<Self, _State> {
                    \Self._modelState
                }

                private nonisolated var _$modelContext: ModelContext<Self> {
                    get {
                        ModelContext(_access: _$modelAccess, _source: _$modelSource)
                    }
                }

                public nonisolated var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                public nonisolated mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelAccess = update._$modelContext._access
                    _$modelSource = update._$modelContext._source
                }
            }

            nonisolated extension MyModel: SwiftModel.Model {
            }

            nonisolated extension MyModel: @unchecked Sendable {
            }

            nonisolated extension MyModel: Identifiable {
            }

            nonisolated extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("id", id as Any), ("count", count as Any)])
                }
            }

            nonisolated extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
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
                    @storageRestrictions(initializes: _$modelAccess, _$modelSource)
                    init(newValue) {
                        _$modelAccess = _ModelAccessBox()
                        _ModelSourceBox<Self>._threadLocalStoreFirst(\.count, newValue)
                        _$modelSource = ._popFromThreadLocal(Self._makeState)
                    }
                    _read {
                        yield _$modelSource[read: \_State.count, access: _$modelAccess]
                    }
                    nonmutating _modify {
                        yield &_$modelSource[write: \_State.count, access: _$modelAccess]
                    }
                }

                public nonisolated func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    visitor.visitStatically(statePath: \.count)
                }

                public nonisolated struct _State: _ModelStateType {
                    var count = 0
                }

                public typealias _ModelState = _State

                private nonisolated static func _makeState(from pending: PendingStorage<_State>) -> _State {
                    _State(count: pending.value(for: \.count, default: 0))
                }

                private nonisolated var _modelState: _State {
                    get {
                        _$modelSource._modelState
                    }
                    nonmutating set {
                        _$modelSource._modelState = newValue
                    }
                }

                private var _$modelAccess: _ModelAccessBox = _ModelAccessBox()

                private var _$modelSource: _ModelSourceBox<Self> = ._popFromThreadLocal(Self._makeState)

                public nonisolated static var _modelStateKeyPath: WritableKeyPath<Self, _State> {
                    \Self._modelState
                }

                private nonisolated var _$modelContext: ModelContext<Self> {
                    get {
                        ModelContext(_access: _$modelAccess, _source: _$modelSource)
                    }
                }

                public nonisolated var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                public nonisolated mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelAccess = update._$modelContext._access
                    _$modelSource = update._$modelContext._source
                }
            }

            nonisolated extension MyModel: SwiftModel.Model {
            }

            nonisolated extension MyModel: @unchecked Sendable {
            }

            nonisolated extension MyModel: Identifiable {
            }

            nonisolated extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("count", count as Any)])
                }
            }

            nonisolated extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
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
                    @storageRestrictions(initializes: _$modelAccess, _$modelSource)
                    init(newValue) {
                        _$modelAccess = _ModelAccessBox()
                        _ModelSourceBox<Self>._threadLocalStoreFirst(\.animating, newValue)
                        _$modelSource = ._popFromThreadLocal(Self._makeState)
                    }
                    _read {
                        yield _$modelSource[read: \_State.animating, access: _$modelAccess]
                    }
                    nonmutating _modify {
                        yield &_$modelSource[write: \_State.animating, access: _$modelAccess]
                    }
                }

                public nonisolated func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    visitor.visitStatically(statePath: \.animating, visibility: .private)
                }

                public nonisolated struct _State: _ModelStateType {
                    var animating = false
                }

                public typealias _ModelState = _State

                private nonisolated static func _makeState(from pending: PendingStorage<_State>) -> _State {
                    _State(animating: pending.value(for: \.animating, default: false))
                }

                private nonisolated var _modelState: _State {
                    get {
                        _$modelSource._modelState
                    }
                    nonmutating set {
                        _$modelSource._modelState = newValue
                    }
                }

                private var _$modelAccess: _ModelAccessBox = _ModelAccessBox()

                private var _$modelSource: _ModelSourceBox<Self> = ._popFromThreadLocal(Self._makeState)

                public nonisolated static var _modelStateKeyPath: WritableKeyPath<Self, _State> {
                    \Self._modelState
                }

                private nonisolated var _$modelContext: ModelContext<Self> {
                    get {
                        ModelContext(_access: _$modelAccess, _source: _$modelSource)
                    }
                }

                public nonisolated var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                public nonisolated mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelAccess = update._$modelContext._access
                    _$modelSource = update._$modelContext._source
                }
            }

            nonisolated extension MyModel: SwiftModel.Model {
            }

            nonisolated extension MyModel: @unchecked Sendable {
            }

            nonisolated extension MyModel: Identifiable {
            }

            nonisolated extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("animating", animating as Any)])
                }
            }

            nonisolated extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
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

    /// Mixed model: one no-default property, two defaulted.
    @Test func testModelMixedProperties() {
        assertMacro {
            """
            @Model struct MyModel {
                var count = 0
                var label: String
                var flag = false
            }
            """
        } expansion: {
            #"""
            struct MyModel {
                var count = 0 {
                    @storageRestrictions(initializes: _$modelAccess)
                    init(newValue) {
                        _$modelAccess = _ModelAccessBox()
                        _ModelSourceBox<Self>._threadLocalStoreFirst(\.count, newValue)
                    }
                    _read {
                        yield _$modelSource[read: \_State.count, access: _$modelAccess]
                    }
                    nonmutating _modify {
                        yield &_$modelSource[write: \_State.count, access: _$modelAccess]
                    }
                }
                var label: String {
                    @storageRestrictions(initializes: _$private1)
                    init(newValue) {
                        _$private1 = ()
                        _ModelSourceBox<Self>._threadLocalStoreOrLatest(\.label, newValue)
                    }
                    _read {
                        yield _$modelSource[read: \_State.label, access: _$modelAccess]
                    }
                    nonmutating _modify {
                        yield &_$modelSource[write: \_State.label, access: _$modelAccess]
                    }
                }

                var _$private1: Void
                var flag = false {
                    @storageRestrictions(initializes: _$modelSource)
                    init(newValue) {
                        _$modelSource = _ModelSourceBox<Self>._threadLocalStoreAndPop(\.flag, newValue, Self._makeState)
                    }
                    _read {
                        yield _$modelSource[read: \_State.flag, access: _$modelAccess]
                    }
                    nonmutating _modify {
                        yield &_$modelSource[write: \_State.flag, access: _$modelAccess]
                    }
                }

                public nonisolated func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    visitor.visitStatically(statePath: \.count)
                    visitor.visitStatically(statePath: \.label)
                    visitor.visitStatically(statePath: \.flag)
                }

                public nonisolated struct _State: _ModelStateType {
                    var count = 0
                    var label: String
                    var flag = false
                }

                public typealias _ModelState = _State

                private nonisolated static func _makeState(from pending: PendingStorage<_State>) -> _State {
                    _State(count: pending.value(for: \.count, default: 0), label: pending.value(for: \.label, default: _zeroInit()), flag: pending.value(for: \.flag, default: false))
                }

                private nonisolated var _modelState: _State {
                    get {
                        _$modelSource._modelState
                    }
                    nonmutating set {
                        _$modelSource._modelState = newValue
                    }
                }

                private var _$modelAccess: _ModelAccessBox = _ModelAccessBox()

                private var _$modelSource: _ModelSourceBox<Self> = ._popFromThreadLocal(Self._makeState)

                public nonisolated static var _modelStateKeyPath: WritableKeyPath<Self, _State> {
                    \Self._modelState
                }

                private nonisolated var _$modelContext: ModelContext<Self> {
                    get {
                        ModelContext(_access: _$modelAccess, _source: _$modelSource)
                    }
                }

                public nonisolated var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                public nonisolated mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelAccess = update._$modelContext._access
                    _$modelSource = update._$modelContext._source
                }
            }

            nonisolated extension MyModel: SwiftModel.Model {
            }

            nonisolated extension MyModel: @unchecked Sendable {
            }

            nonisolated extension MyModel: Identifiable {
            }

            nonisolated extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("count", count as Any), ("label", label as Any), ("flag", flag as Any)])
                }
            }

            nonisolated extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
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

    /// Model with a `let` property and an `@_ModelIgnored` stored var.
    @Test func testModelLetAndIgnored() {
        assertMacro {
            """
            @Model struct MyModel {
                let id: Int
                @_ModelIgnored var tag: String
                var count = 0
            }
            """
        } expansion: {
            #"""
            struct MyModel {
                let id: Int
                var tag: String
                var count = 0 {
                    @storageRestrictions(initializes: _$modelAccess, _$modelSource)
                    init(newValue) {
                        _$modelAccess = _ModelAccessBox()
                        _ModelSourceBox<Self>._threadLocalStoreFirst(\.count, newValue)
                        _$modelSource = ._popFromThreadLocal(Self._makeState)
                    }
                    _read {
                        yield _$modelSource[read: \_State.count, access: _$modelAccess]
                    }
                    nonmutating _modify {
                        yield &_$modelSource[write: \_State.count, access: _$modelAccess]
                    }
                }

                public nonisolated func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    visitor.visitStatically(at: \.id)
                    visitor.visitStatically(statePath: \.count)
                }

                public nonisolated struct _State: _ModelStateType {
                    var count = 0
                }

                public typealias _ModelState = _State

                private nonisolated static func _makeState(from pending: PendingStorage<_State>) -> _State {
                    _State(count: pending.value(for: \.count, default: 0))
                }

                private nonisolated var _modelState: _State {
                    get {
                        _$modelSource._modelState
                    }
                    nonmutating set {
                        _$modelSource._modelState = newValue
                    }
                }

                private var _$modelAccess: _ModelAccessBox = _ModelAccessBox()

                private var _$modelSource: _ModelSourceBox<Self> = ._popFromThreadLocal(Self._makeState)

                public nonisolated static var _modelStateKeyPath: WritableKeyPath<Self, _State> {
                    \Self._modelState
                }

                private nonisolated var _$modelContext: ModelContext<Self> {
                    get {
                        ModelContext(_access: _$modelAccess, _source: _$modelSource)
                    }
                }

                public nonisolated var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                public nonisolated mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelAccess = update._$modelContext._access
                    _$modelSource = update._$modelContext._source
                }
            }

            nonisolated extension MyModel: SwiftModel.Model {
            }

            nonisolated extension MyModel: @unchecked Sendable {
            }

            nonisolated extension MyModel: Identifiable {
            }

            nonisolated extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("id", id as Any), ("tag", tag as Any), ("count", count as Any)])
                }
            }

            nonisolated extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
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

    /// Model with only a child model property.
    @Test func testModelChildModel() {
        assertMacro {
            """
            @Model struct ParentModel {
                var counter = ChildModel()
            }
            """
        } expansion: {
            #"""
            struct ParentModel {
                var counter = ChildModel() {
                    @storageRestrictions(initializes: _$modelAccess, _$modelSource)
                    init(newValue) {
                        _$modelAccess = _ModelAccessBox()
                        _ModelSourceBox<Self>._threadLocalStoreFirst(\.counter, newValue)
                        _$modelSource = ._popFromThreadLocal(Self._makeState)
                    }
                    _read {
                        yield _$modelSource[read: \_State.counter, access: _$modelAccess]
                    }
                    nonmutating _modify {
                        yield &_$modelSource[write: \_State.counter, access: _$modelAccess]
                    }
                }

                public nonisolated func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    visitor.visitStatically(statePath: \.counter)
                }

                public nonisolated struct _State: _ModelStateType {
                    var counter = ChildModel()
                }

                public typealias _ModelState = _State

                private nonisolated static func _makeState(from pending: PendingStorage<_State>) -> _State {
                    _State(counter: pending.value(for: \.counter, default: ChildModel()))
                }

                private nonisolated var _modelState: _State {
                    get {
                        _$modelSource._modelState
                    }
                    nonmutating set {
                        _$modelSource._modelState = newValue
                    }
                }

                private var _$modelAccess: _ModelAccessBox = _ModelAccessBox()

                private var _$modelSource: _ModelSourceBox<Self> = ._popFromThreadLocal(Self._makeState)

                public nonisolated static var _modelStateKeyPath: WritableKeyPath<Self, _State> {
                    \Self._modelState
                }

                private nonisolated var _$modelContext: ModelContext<Self> {
                    get {
                        ModelContext(_access: _$modelAccess, _source: _$modelSource)
                    }
                }

                public nonisolated var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                public nonisolated mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelAccess = update._$modelContext._access
                    _$modelSource = update._$modelContext._source
                }
            }

            nonisolated extension ParentModel: SwiftModel.Model {
            }

            nonisolated extension ParentModel: @unchecked Sendable {
            }

            nonisolated extension ParentModel: Identifiable {
            }

            nonisolated extension ParentModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("counter", counter as Any)])
                }
            }

            nonisolated extension ParentModel: CustomStringConvertible, CustomDebugStringConvertible {
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

    /// Model with only a @ModelDependency — zero tracked vars.
    @Test func testModelDependency() {
        assertMacro {
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

                public nonisolated func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {

                }

                var _$modelContext: ModelContext<Self> = .init()

                public nonisolated var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                public nonisolated mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelContext = update._$modelContext
                }
            }

            nonisolated extension MyModel: SwiftModel.Model {
            }

            nonisolated extension MyModel: @unchecked Sendable {
            }

            nonisolated extension MyModel: Identifiable {
            }

            nonisolated extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [])
                }
            }

            nonisolated extension MyModel: CustomStringConvertible, CustomDebugStringConvertible {
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
    // When the user declares CustomStringConvertible in the inheritance clause (or in a separate
    // extension — handled at real compile time via the `conformingTo protocols` parameter), the
    // macro skips generating the description/debugDescription extension.
    @Test func testCustomStringConvertibleOverride() {
        assertMacro {
            """
            @Model struct MyModel: CustomStringConvertible {
                var count = 0
                var description: String { "MyModel(\\(count))" }
            }
            """
        } expansion: {
            #"""
            struct MyModel: CustomStringConvertible {
                var count = 0 {
                    @storageRestrictions(initializes: _$modelAccess, _$modelSource)
                    init(newValue) {
                        _$modelAccess = _ModelAccessBox()
                        _ModelSourceBox<Self>._threadLocalStoreFirst(\.count, newValue)
                        _$modelSource = ._popFromThreadLocal(Self._makeState)
                    }
                    _read {
                        yield _$modelSource[read: \_State.count, access: _$modelAccess]
                    }
                    nonmutating _modify {
                        yield &_$modelSource[write: \_State.count, access: _$modelAccess]
                    }
                }
                var description: String { "MyModel(\(count))" }

                public nonisolated func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    visitor.visitStatically(statePath: \.count)
                }

                public nonisolated struct _State: _ModelStateType {
                    var count = 0
                }

                public typealias _ModelState = _State

                private nonisolated static func _makeState(from pending: PendingStorage<_State>) -> _State {
                    _State(count: pending.value(for: \.count, default: 0))
                }

                private nonisolated var _modelState: _State {
                    get {
                        _$modelSource._modelState
                    }
                    nonmutating set {
                        _$modelSource._modelState = newValue
                    }
                }

                private var _$modelAccess: _ModelAccessBox = _ModelAccessBox()

                private var _$modelSource: _ModelSourceBox<Self> = ._popFromThreadLocal(Self._makeState)

                public nonisolated static var _modelStateKeyPath: WritableKeyPath<Self, _State> {
                    \Self._modelState
                }

                private nonisolated var _$modelContext: ModelContext<Self> {
                    get {
                        ModelContext(_access: _$modelAccess, _source: _$modelSource)
                    }
                }

                public nonisolated var _context: ModelContextAccess<Self> {
                    ModelContextAccess(_$modelContext)
                }

                public nonisolated mutating func _updateContext(_ update: ModelContextUpdate<Self>) {
                    _$modelAccess = update._$modelContext._access
                    _$modelSource = update._$modelContext._source
                }
            }

            nonisolated extension MyModel: SwiftModel.Model {
            }

            nonisolated extension MyModel: @unchecked Sendable {
            }

            nonisolated extension MyModel: Identifiable {
            }

            nonisolated extension MyModel: CustomReflectable {
                public var customMirror: Mirror {
                    node.mirror(of: self, children: [("count", count as Any)])
                }
            }

            nonisolated extension MyModel: CustomDebugStringConvertible {
                public var debugDescription: String {
                    description
                }
            }
            """#
        }
    }
}

#endif // canImport(SwiftModelMacros)
