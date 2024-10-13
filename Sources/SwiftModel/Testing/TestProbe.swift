import Foundation
import XCTestDynamicOverlay
import CustomDump

public final class TestProbe: @unchecked Sendable {
    let name: String?
    private let lock = NSRecursiveLock()
    private var _values: [Any] = []

    public init(_ name: String? = nil) {
        self.name = name
    }
}

public extension TestProbe {
    @Sendable func call() {
        _call()
    }

    @Sendable func call<T>(_ value: T) {
        _call(value)
    }

    @Sendable func call<T1, T2>(_ value1: T1, _ value2: T2) {
        _call(value1, value2)
    }

    @Sendable func call<each S>(_ value: repeat each S) {
        _call(repeat each value)
    }

    private func _call<each S>(_ value: repeat each S) {
        lock {
            _values.append((repeat each value))
        }
    }

    @Sendable func callAsFunction<each S>(_ value: repeat each S) {
        lock {
            _values.append((repeat each value))
        }
    }

    var count: Int { values.count }
    var isEmpty: Bool { values.isEmpty }

    func wasCalled<each S>(with value: repeat each S, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let context = TesterAssertContextBase.assertContext else {
            XCTFail("Can only call wasCalled inside a ModelTester assert", file: file, line: line)
            return false
        }

        let tuple = (repeat each value)
        context.probe(self, wasCalledWith: (repeat each value))
        return index(of: tuple) != nil
    }
}

extension TestProbe {
    func index(of value: Any) -> Int? {
       values.firstIndex {
           diff($0, value) == nil
       }
    }

    func consume(_ value: Any) {
        lock {
            if let index = index(of: value) {
                _values.remove(at: index)
            }
        }
    }

    var values: [Any] { lock(_values) }
}

struct NoArgs: Equatable {}
