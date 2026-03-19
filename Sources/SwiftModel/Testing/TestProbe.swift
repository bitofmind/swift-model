import Foundation
import IssueReporting
import CustomDump

/// A recorder for callback invocations, used to assert that closures are called with the
/// expected arguments inside a `ModelTester` test.
///
/// Create a probe, pass it (or `probe.call`) as the callback closure, then assert inside
/// `tester.assert` that it was called with the expected values:
///
/// ```swift
/// @Test func testFactButtonTapped() async {
///     let onFact = TestProbe()
///     let (model, tester) = CounterModel(count: 2, onFact: onFact.call).andTester {
///         $0.factClient.fetch = { "\($0) is a good number." }
///     }
///     tester.install(onFact)   // opt into exhaustion checking
///
///     model.factButtonTapped()
///
///     await tester.assert {
///         onFact.wasCalled(with: 2, "2 is a good number.")
///     }
/// }
/// ```
///
/// `TestProbe` is `@Sendable`-safe and can be passed into model closures without capture-list concerns.
public final class TestProbe: @unchecked Sendable {
    let name: String?
    private let lock = NSRecursiveLock()
    private var _values: [Any] = []

    /// Creates a probe, optionally named for clearer failure messages.
    ///
    /// The probe automatically registers with the active `.modelTesting` test scope on creation,
    /// so any calls to it will be caught by exhaustion checking. Pass `autoInstall: false` only
    /// when creating probes inside shared test helpers that should not participate in exhaustion
    /// unless the probe is explicitly passed to a model.
    public init(_ name: String? = nil, autoInstall: Bool = true) {
        self.name = name
        if autoInstall { autoInstallIfNeeded() }
    }
}

public extension TestProbe {
    /// Records a call with no arguments.
    @Sendable func call() {
        _call()
    }

    /// Records a call with one argument.
    @Sendable func call<T>(_ value: T) {
        _call(value)
    }

    /// Records a call with two arguments.
    @Sendable func call<T1, T2>(_ value1: T1, _ value2: T2) {
        _call(value1, value2)
    }

    /// Records a call with any number of arguments.
    @Sendable func call<each S>(_ value: repeat each S) {
        _call(repeat each value)
    }

    private func _call<each S>(_ value: repeat each S) {
        lock {
            _values.append((repeat each value))
        }
        autoInstallIfNeeded()
    }

    /// Allows the probe to be used directly as a closure (e.g. `onSave: probe`).
    /// Equivalent to calling `probe.call(value)`.
    @Sendable func callAsFunction<each S>(_ value: repeat each S) {
        lock {
            _values.append((repeat each value))
        }
        autoInstallIfNeeded()
    }

    private func autoInstallIfNeeded() {
        guard let scope = _ModelTestingLocals.scope else { return }
        scope.install([self])
    }

    /// Registers this probe with the active `.modelTesting` test scope.
    ///
    /// Probes created inside a `.modelTesting` test auto-register at `init` time, so calling
    /// `install()` explicitly is only needed when a probe was created with `autoInstall: false`.
    func install(fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) {
        guard let scope = _ModelTestingLocals.scope else {
            reportIssue("install() must be called inside a @Test(.modelTesting) test function", fileID: fileID, filePath: filePath, line: line, column: column)
            return
        }
        scope.install([self])
    }

    /// The number of times the probe has been called.
    var count: Int { values.count }

    /// `true` if the probe has never been called.
    var isEmpty: Bool { values.isEmpty }

    /// Asserts — inside a `tester.assert { }` or `expect { }` block — that the probe was called
    /// with the given arguments. Matching uses `customDump` equality, so you get a readable diff on failure.
    ///
    /// ```swift
    /// await expect {
    ///     onLoad.wasCalled(with: "hello")
    /// }
    /// ```
    ///
    /// > Important: This method must be called inside a `ModelTester.assert` or `expect { }` builder block.
    ///   Calling it outside will report an issue and return `false`.
    func wasCalled<each S>(with value: repeat each S, filePath: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let context = TesterAssertContextBase.assertContext else {
            reportIssue("Can only call wasCalled inside a ModelTester assert or expect block", filePath: filePath, line: line)
            return false
        }

        let tuple = (repeat each value)
        context.probe(self, wasCalledWith: (repeat each value))
        return index(of: tuple) != nil
    }

}

extension TestProbe {
    func index(of value: Any) -> Int? {
       values.firstIndex { element in
           threadLocals.withValue(true, at: \.includeChildrenInMirror) { diff(element, value) == nil }
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
