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
    "ModelContainer": ModelContainerMacro.self,
]))
struct ModelContainerMacroTests {
    @Test func testStructModelContainer() {
        assertMacro {
            """
            @ModelContainer struct Container {
                var count = 4711
                var model: Model
            }
            """
        } expansion: {
            #"""
            struct Container {
                var count = 4711
                var model: Model
            }

            extension Container: SwiftModel.ModelContainer {
                public func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    visitor.visitStatically(at: \.count)
                    visitor.visitStatically(at: \.model)
                }
            }
            """#
        }
    }

    @Test func testEnumModelContainer() {
        assertMacro {
            """
            @ModelContainer enum Container {
                case empty
                case single(Double)
                case singleNamed(double: Double)
                case double(integer: Int, string: String)
                case doubleMix(Int, string: String)
            }
            """
        } expansion: {
            """
            enum Container {
                case empty
                case single(Double)
                case singleNamed(double: Double)
                case double(integer: Int, string: String)
                case doubleMix(Int, string: String)
            }

            extension Container: SwiftModel.ModelContainer {
                public func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    switch self {
                    case .empty:
                        break
                    case let .single(value1):
                        visitor.visitStatically(at: path(caseName: "single", value: value1) { root in
                                if case let .single(value1) = root {
                                    value1
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case  .single(_) = root {
                                    let value1 = value
                                    root = .single(value1)
                                }
                            })

                    case let .singleNamed(double: value1):
                        visitor.visitStatically(at: path(caseName: "singleNamed", value: value1) { root in
                                if case let .singleNamed(double: value1) = root {
                                    value1
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case  .singleNamed(double: _) = root {
                                    let value1 = value
                                    root = .singleNamed(double: value1)
                                }
                            })

                    case let .double(integer: value1, string: value2):
                        visitor.visitStatically(at: path(caseName: "double.0", value: value1) { root in
                                if case let .double(integer: value1, string: _) = root {
                                    value1
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case let .double(integer: _, string: value2) = root {
                                    let value1 = value
                                    root = .double(integer: value1, string: value2)
                                }
                            })

                        visitor.visitStatically(at: path(caseName: "double.1", value: value2) { root in
                                if case let .double(integer: _, string: value2) = root {
                                    value2
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case let .double(integer: value1, string: _) = root {
                                    let value2 = value
                                    root = .double(integer: value1, string: value2)
                                }
                            })

                    case let .doubleMix(value1, string: value2):
                        visitor.visitStatically(at: path(caseName: "doubleMix.0", value: value1) { root in
                                if case let .doubleMix(value1, string: _) = root {
                                    value1
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case let .doubleMix(_, string: value2) = root {
                                    let value1 = value
                                    root = .doubleMix(value1, string: value2)
                                }
                            })

                        visitor.visitStatically(at: path(caseName: "doubleMix.1", value: value2) { root in
                                if case let .doubleMix(_, string: value2) = root {
                                    value2
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case let .doubleMix(value1, string: _) = root {
                                    let value2 = value
                                    root = .doubleMix(value1, string: value2)
                                }
                            })


                    }
                }

              }
            """
        }
    }

    @Test func testHashableEnumModelContainer() {
        assertMacro {
            """
            @ModelContainer enum Nav: Hashable {
                case home
                case detail(DetailModel)
                case settings(SettingsModel)
            }
            """
        } expansion: {
            """
            enum Nav: Hashable {
                case home
                case detail(DetailModel)
                case settings(SettingsModel)

                public func hash(into hasher: inout Hasher) {
                    switch self {
                    case .home:
                    hasher.combine("home")
                    case let .detail(v1):
                    hasher.combine("detail")
                    _modelCombine(into: &hasher, v1)
                    case let .settings(v1):
                    hasher.combine("settings")
                    _modelCombine(into: &hasher, v1)
                    }
                }
            }

            extension Nav: SwiftModel.ModelContainer {
                public func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    switch self {
                    case .home:
                        break
                    case let .detail(value1):
                        visitor.visitStatically(at: path(caseName: "detail", value: value1) { root in
                                if case let .detail(value1) = root {
                                    value1
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case  .detail(_) = root {
                                    let value1 = value
                                    root = .detail(value1)
                                }
                            })

                    case let .settings(value1):
                        visitor.visitStatically(at: path(caseName: "settings", value: value1) { root in
                                if case let .settings(value1) = root {
                                    value1
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case  .settings(_) = root {
                                    let value1 = value
                                    root = .settings(value1)
                                }
                            })


                    }
                }

              }

            extension Nav: Equatable {
                public static func == (lhs: Self, rhs: Self) -> Bool {
                    switch (lhs, rhs) {
                    case (.home, .home):
                        return true
                    case let (.detail(l1), .detail(r1)):
                        return _modelEqual(l1, r1)
                    case let (.settings(l1), .settings(r1)):
                        return _modelEqual(l1, r1)
                    default:
                        return false
                    }
                }
            }
            """
        }
    }

    @Test func testHashableEnumWithNamedParams() {
        assertMacro {
            """
            @ModelContainer enum Nav: Hashable {
                case detail(model: DetailModel)
                case edit(item: ItemModel, meta: MetaModel)
            }
            """
        } expansion: {
            """
            enum Nav: Hashable {
                case detail(model: DetailModel)
                case edit(item: ItemModel, meta: MetaModel)

                public func hash(into hasher: inout Hasher) {
                    switch self {
                    case let .detail(model: v1):
                    hasher.combine("detail")
                    _modelCombine(into: &hasher, v1)
                    case let .edit(item: v1, meta: v2):
                    hasher.combine("edit")
                    _modelCombine(into: &hasher, v1)
                        _modelCombine(into: &hasher, v2)
                    }
                }
            }

            extension Nav: SwiftModel.ModelContainer {
                public func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    switch self {
                    case let .detail(model: value1):
                        visitor.visitStatically(at: path(caseName: "detail", value: value1) { root in
                                if case let .detail(model: value1) = root {
                                    value1
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case  .detail(model: _) = root {
                                    let value1 = value
                                    root = .detail(model: value1)
                                }
                            })

                    case let .edit(item: value1, meta: value2):
                        visitor.visitStatically(at: path(caseName: "edit.0", value: value1) { root in
                                if case let .edit(item: value1, meta: _) = root {
                                    value1
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case let .edit(item: _, meta: value2) = root {
                                    let value1 = value
                                    root = .edit(item: value1, meta: value2)
                                }
                            })

                        visitor.visitStatically(at: path(caseName: "edit.1", value: value2) { root in
                                if case let .edit(item: _, meta: value2) = root {
                                    value2
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case let .edit(item: value1, meta: _) = root {
                                    let value2 = value
                                    root = .edit(item: value1, meta: value2)
                                }
                            })


                    }
                }

              }

            extension Nav: Equatable {
                public static func == (lhs: Self, rhs: Self) -> Bool {
                    switch (lhs, rhs) {
                    case let (.detail(model: l1), .detail(model: r1)):
                        return _modelEqual(l1, r1)
                    case let (.edit(item: l1, meta: l2), .edit(item: r1, meta: r2)):
                        return _modelEqual(l1, r1) && _modelEqual(l2, r2)
                    default:
                        return false
                    }
                }
            }
            """
        }
    }

    @Test func testHashableNotSynthesisedWhenManualImplementation() {
        assertMacro {
            """
            @ModelContainer enum Nav: Hashable {
                case detail(DetailModel)
                static func == (lhs: Self, rhs: Self) -> Bool { false }
                func hash(into hasher: inout Hasher) {}
            }
            """
        } expansion: {
            """
            enum Nav: Hashable {
                case detail(DetailModel)
                static func == (lhs: Self, rhs: Self) -> Bool { false }
                func hash(into hasher: inout Hasher) {}
            }

            extension Nav: SwiftModel.ModelContainer {
                public func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    switch self {
                    case let .detail(value1):
                        visitor.visitStatically(at: path(caseName: "detail", value: value1) { root in
                                if case let .detail(value1) = root {
                                    value1
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case  .detail(_) = root {
                                    let value1 = value
                                    root = .detail(value1)
                                }
                            })


                    }
                }

              }
            """
        }
    }

    @Test func testIdentifiableEnumModelContainer() {
        assertMacro {
            """
            @ModelContainer enum Nav: Hashable, Identifiable {
                case home
                case detail(DetailModel)
            }
            """
        } expansion: {
            """
            enum Nav: Hashable, Identifiable {
                case home
                case detail(DetailModel)

                public func hash(into hasher: inout Hasher) {
                    switch self {
                    case .home:
                    hasher.combine("home")
                    case let .detail(v1):
                    hasher.combine("detail")
                    _modelCombine(into: &hasher, v1)
                    }
                }

                public var id: _ModelContainerCaseID {
                    switch self {
                    case .home:
                    _ModelContainerCaseID(caseName: "home", values: [])
                    case let .detail(v1):
                    _ModelContainerCaseID(caseName: "detail", values: [_modelIdentity(v1)])
                    }
                }
            }

            extension Nav: SwiftModel.ModelContainer {
                public func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    switch self {
                    case .home:
                        break
                    case let .detail(value1):
                        visitor.visitStatically(at: path(caseName: "detail", value: value1) { root in
                                if case let .detail(value1) = root {
                                    value1
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case  .detail(_) = root {
                                    let value1 = value
                                    root = .detail(value1)
                                }
                            })


                    }
                }

              }

            extension Nav: Equatable {
                public static func == (lhs: Self, rhs: Self) -> Bool {
                    switch (lhs, rhs) {
                    case (.home, .home):
                        return true
                    case let (.detail(l1), .detail(r1)):
                        return _modelEqual(l1, r1)
                    default:
                        return false
                    }
                }
            }
            """
        }
    }

    @Test func testIdentifiableNotSynthesisedWhenManualId() {
        assertMacro {
            """
            @ModelContainer enum Nav: Hashable, Identifiable {
                case detail(DetailModel)
                var id: String { "manual" }
            }
            """
        } expansion: {
            """
            enum Nav: Hashable, Identifiable {
                case detail(DetailModel)
                var id: String { "manual" }

                public func hash(into hasher: inout Hasher) {
                    switch self {
                    case let .detail(v1):
                    hasher.combine("detail")
                    _modelCombine(into: &hasher, v1)
                    }
                }
            }

            extension Nav: SwiftModel.ModelContainer {
                public func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    switch self {
                    case let .detail(value1):
                        visitor.visitStatically(at: path(caseName: "detail", value: value1) { root in
                                if case let .detail(value1) = root {
                                    value1
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case  .detail(_) = root {
                                    let value1 = value
                                    root = .detail(value1)
                                }
                            })


                    }
                }

              }

            extension Nav: Equatable {
                public static func == (lhs: Self, rhs: Self) -> Bool {
                    switch (lhs, rhs) {
                    case let (.detail(l1), .detail(r1)):
                        return _modelEqual(l1, r1)
                    }
                }
            }
            """
        }
    }

    @Test func testIdentifiableOnlyEnum() {
        assertMacro {
            """
            @ModelContainer enum Nav: Identifiable {
                case home
                case detail(DetailModel)
            }
            """
        } expansion: {
            """
            enum Nav: Identifiable {
                case home
                case detail(DetailModel)

                public var id: _ModelContainerCaseID {
                    switch self {
                    case .home:
                    _ModelContainerCaseID(caseName: "home", values: [])
                    case let .detail(v1):
                    _ModelContainerCaseID(caseName: "detail", values: [_modelIdentity(v1)])
                    }
                }
            }

            extension Nav: SwiftModel.ModelContainer {
                public func visit<V: ModelVisitor<Self>>(with visitor: inout ContainerVisitor<V>) {
                    switch self {
                    case .home:
                        break
                    case let .detail(value1):
                        visitor.visitStatically(at: path(caseName: "detail", value: value1) { root in
                                if case let .detail(value1) = root {
                                    value1
                                } else {
                                    nil
                                }
                            } set: { root, value in
                                if case  .detail(_) = root {
                                    let value1 = value
                                    root = .detail(value1)
                                }
                            })


                    }
                }

              }
            """
        }
    }

    @Test func testClassModelContainer() {
        assertMacro {
            """
            @ModelContainer class Container {
                var model: Model
            }
            """
        } diagnostics: {
            """
            @ModelContainer class Container {
            ┬──────────────
            ╰─ 🛑 Requires type to be either struct or enum
                var model: Model
            }
            """
        }
    }
}

#endif // canImport(SwiftModelMacros)
