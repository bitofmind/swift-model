import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import Testing
import SwiftModelMacros
import Dependencies
import MacroTesting

@Suite(.macros([
    "ModelContainer": ModelContainerMacro.self,
], record: .never))
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
                public func visit(with visitor: inout ContainerVisitor<Self>) {
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
                public func visit(with visitor: inout ContainerVisitor<Self>) {
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
