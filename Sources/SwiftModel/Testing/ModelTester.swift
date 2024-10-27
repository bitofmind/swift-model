import Foundation
import AsyncAlgorithms
import Dependencies
import IssueReporting
import CustomDump

/// An model tester is used when testing models
public final class ModelTester<M: Model> {
    let access: TestAccess<M>
    let fileAndLine: FileAndLine

    /// Creates model tester for testing models.
    ///
    ///     ModelTester(AppModel()) {
    ///        $0.uuid = .incrementing
    ///        $0.locale = Locale(identifier: "en_US")
    ///     }
    ///
    /// - Parameter model: An un-anchored model to test.
    /// - Parameter dependencies: A closure for to overriding dependencies that will be accessed by the model
    ///
    ///  - Note: It is often more convenient to use the `andTester()` method on a model.
    public init(_ model: M, dependencies: (inout ModelDependencies) -> Void = { _ in }, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) {
        fileAndLine = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        access = TestAccess(model: model, dependencies: dependencies, fileAndLine: fileAndLine)
    }

    public var model: M {
        access.context.model
    }

    deinit {
        access.context.cancelAllRecursively(for: ContextCancellationKey.onActivate)
        access.checkExhaustion(at: fileAndLine, includeUpdates: false, checkTasks: true)
        access.context.onRemoval()
    }
}

public extension Model {
    /// Create a model test using self and returns the model and the tester
    ///
    ///     let (appModel, tester) = AppModel().andTester())
    ///
    /// Or if you need to override some dependencies:
    ///
    ///     let (appModel, tester) = AppModel().andTester {
    ///        $0.uuid = .incrementing
    ///        $0.locale = Locale(identifier: "en_US")
    ///     }
    ///
    /// - Parameter dependencies: A closure for to overriding dependencies that will be accessed by the model
    func andTester(withDependencies dependencies: (inout ModelDependencies) -> Void = { _ in }, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, function: String = #function) -> (Self, ModelTester<Self>) {
        assertInitialState(function: function)
        let tester = ModelTester(self, dependencies: dependencies, fileID: fileID, filePath: filePath, line: line, column: column)
        return (tester.model, tester)
    }
}

public extension Model {
    func didSend(_ event: Event, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) -> Bool {
        didSend(event as Any, filePath: filePath, line: line)
    }

    func didSend(_ event: Any, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) -> Bool {
        guard let assertContext = TesterAssertContextBase.assertContext else {
            reportIssue("Can only call didSend inside a ModelTester assert", filePath: filePath, line: line)
            return false
        }

        guard lifetime >= .active else {
            reportIssue("Can only call didSend on models that is part of a ModelTester", filePath: filePath, line: line)
            return false
        }

        guard let context = enforcedContext() else { return false }
        return assertContext.didSend(event: event, from: context)
    }
}

public extension ModelTester {
    var exhaustivity: Exhaustivity {
        get { access.lock { access.exhaustivity } }
        set { access.lock { access.exhaustivity = newValue } }
    }

    var showSkippedAssertions: Bool {
        get { access.lock { access.showSkippedAssertions } }
        set { access.lock { access.showSkippedAssertions = newValue } }
    }

    func install(_ probes: TestProbe...) {
        for probe in probes {
            access.install(probe)
        }
    }
}

public struct Exhaustivity: OptionSet, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

public extension Exhaustivity {
    static let state = Self(rawValue: 1 << 0)
    static let events = Self(rawValue: 1 << 1)
    static let tasks = Self(rawValue: 1 << 2)
    static let probes = Self(rawValue: 1 << 3)

    static let off: Self = []
    static let full: Self = [.state, .events, .tasks, .probes]
}

@resultBuilder
public enum AssertBuilder { }

public extension AssertBuilder {
    struct Predicate {
        var predicate: () -> Bool
        var values: () -> (Any, Any)? = { nil }
        var fileAndLine: FileAndLine
    }
    typealias Result = [Predicate]

    static func buildBlock(_ layers: Result...) -> Result {
        layers.flatMap { $0 }
    }

    @_disfavoredOverload
    static func buildExpression(_ predicate: @autoclosure @escaping () -> Bool, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) -> Result {
        [Predicate(predicate: predicate, fileAndLine: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column))]
    }

    static func buildExpression(_ predicate: TestPredicate, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) -> Result {
        [Predicate(predicate: predicate.predicate, values: predicate.values, fileAndLine: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column))]
    }
}

func predicate(@AssertBuilder _ builder: () -> AssertBuilder.Result) -> Bool {
    let result = builder()

    return result.allSatisfy { $0.predicate() }
}

public struct TestPredicate {
    var predicate: () -> Bool
    var values: () -> (Any, Any)? = { nil }
}

public func == <T: Equatable>(lhs: @escaping @autoclosure () -> T, rhs: @escaping @autoclosure () -> T) -> TestPredicate {
    TestPredicate(predicate: { lhs() == rhs() }, values: { (lhs(), rhs()) })
}

public extension ModelTester {
    func assert(timeoutNanoseconds timeout: UInt64 = NSEC_PER_SEC, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column, @AssertBuilder _ builder: () -> AssertBuilder.Result) async {
        await access.assert(timeoutNanoseconds: timeout, at: FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column), predicates: builder())
    }

    @_disfavoredOverload
    func assert(_ predicate: @escaping @autoclosure () -> Bool, timeoutNanoseconds timeout: UInt64 = NSEC_PER_SEC, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) async {
        let fileAndLine = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        let predicate = AssertBuilder.Predicate(predicate: predicate, fileAndLine: fileAndLine)
        await access.assert(timeoutNanoseconds: timeout, at: fileAndLine, predicates: [predicate])
    }

    func assert(_ predicate: TestPredicate, timeoutNanoseconds timeout: UInt64 = NSEC_PER_SEC, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) async {
        let fileAndLine = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
        let predicate = AssertBuilder.Predicate(predicate: predicate.predicate, values: predicate.values, fileAndLine: fileAndLine)
        await access.assert(timeoutNanoseconds: timeout, at: fileAndLine, predicates: [predicate])
    }

    func unwrap<T>(_ unwrap: @escaping @autoclosure () -> T?, timeoutNanoseconds timeout: UInt64 = NSEC_PER_SEC, fileID: StaticString = #fileID, filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) async throws -> T  {
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            if let value = unwrap() {
                let fileAndLine = FileAndLine(fileID: fileID, filePath: filePath, line: line, column: column)
                let predicate = AssertBuilder.Predicate(predicate: { unwrap() != nil }, fileAndLine: fileAndLine)
                await access.assert(timeoutNanoseconds: timeout, at: fileAndLine, predicates: [predicate], enableExhaustionTest: false)
                return value
            }

            if start.distance(to: DispatchTime.now().uptimeNanoseconds) > timeout {
                reportIssue("Failed to unwrap value", filePath: filePath, line: line)
                throw UnwrapError()
            }

            await Task.yield()
        }
    }
}

private struct UnwrapError: Error { }


