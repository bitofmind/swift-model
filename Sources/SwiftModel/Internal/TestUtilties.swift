import Foundation
import CustomDump
import IssueReporting

extension String {
    func indent(by indent: Int) -> String {
        let indentation = String(repeating: " ", count: indent)
        return indentation + replacingOccurrences(of: "\n", with: "\n\(indentation)")
    }
}

func diffMessage<T>(expected: T, actual: T, title: @autoclosure () -> String) -> String? {
    let equality = isEqual(expected, actual)
    if equality == true {
        return nil
    }
    let message = diff(expected, actual, format: .proportional)
        .map { "\($0.indent(by: 4))\n\n(Expected: −, Actual: +)" }
    
    if let message {
        return "\(title()): …\n\n" + message
    }
    
    if equality == false {
        return """
        \(title()): …
            Expected:
            \(String(customDumping: expected).indent(by: 2))
            Actual:
            \(String(customDumping: actual).indent(by: 2))
        """
    }
    
    return nil
}

func _XCTExpectFailure(failingBlock: () -> Void) {
  #if DEBUG
    guard
      let XCTExpectedFailureOptions = NSClassFromString("XCTExpectedFailureOptions")
        as Any as? NSObjectProtocol,
      let options = XCTExpectedFailureOptions.perform(NSSelectorFromString("nonStrictOptions"))?.takeUnretainedValue()
    else { return }

    let XCTExpectFailureWithOptionsInBlock = unsafeBitCast(
      dlsym(dlopen(nil, RTLD_LAZY), "XCTExpectFailureWithOptionsInBlock"),
      to: (@convention(c) (String?, AnyObject, () -> Void) -> Void).self
    )

    XCTExpectFailureWithOptionsInBlock(nil, options, failingBlock)
  #endif
}


func isEqual<T>(_ lhs: T, _ rhs: T) -> Bool? {
    guard let lhs = lhs as? any Equatable else {
        return nil
    }

    return lhs.isEqual(rhs as! any Equatable)
}

func isEqual<L, R>(_ lhs: L, _ rhs: R) -> Bool? {
    guard let lhs = lhs as? R, let lhs = lhs as? any Equatable, let rhs = rhs as? any Equatable else {
        return nil
    }

    return lhs.isEqual(rhs)
}

extension Equatable {
    func isEqual(_ other: any Equatable) -> Bool {
        guard let other = other as? Self else {
            return other.isExactlyEqual(self)
        }
        return self == other
    }

    private func isExactlyEqual(_ other: any Equatable) -> Bool {
        guard let other = other as? Self else {
            return false
        }
        return self == other
    }
}

func propertyName<M: Model, State>(from model: M, path: WritableKeyPath<M, State>) -> String? {
    let names = Mirror(reflecting: model.withAccess(nil)).children.map(\.label)
    guard let index = model.visitIndex(of: path), names.count > index else { return nil }
    return names[index]
}

extension ModelContainer {
    func visitIndex<T>(of path: WritableKeyPath<Self, T>) -> Int? {
        var visitor = IndexVisitor(path: path)
        visit(with: &visitor, includeSelf: false)
        return visitor.foundIndex
    }
}

struct IndexVisitor<State, Child>: ModelVisitor {
    let path: WritableKeyPath<State, Child>
    var foundIndex: Int?
    var index = 0

    private mutating func check<T>(_ path: KeyPath<State, T>) {
        if path == self.path {
            foundIndex = index
        }

        index += 1
    }

    mutating func visit<T>(path: KeyPath<State, T>) { check(path) }
    mutating func visit<T>(path: WritableKeyPath<State, T>) { check(path) }
    mutating func visit<T: Model>(path: WritableKeyPath<State, T>) { check(path) }
    mutating func visit<T: ModelContainer>(path: WritableKeyPath<State, T>) { check(path) }
}

func isSame<each T: Equatable>(_ lhs: (repeat each T), _ rhs: (repeat each T)) -> Bool {
    for (left, right) in repeat (each lhs, each rhs) {
        guard left == right else {
            return false
        }
    }
    return true
}

func isSame<each T: Equatable>(_ lhs: (repeat each T)?, _ rhs: (repeat each T)?) -> Bool {
    switch (lhs, rhs) {
    case let (lhs?, rhs?):
        for (left, right) in repeat (each lhs, each rhs) {
            guard left == right else {
                return false
            }
        }
        return true
    case (nil, nil):
        return true
    default:
        return false
    }
}
