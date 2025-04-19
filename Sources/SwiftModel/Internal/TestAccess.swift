import Foundation
import CustomDump
import IssueReporting
import Dependencies

final class TestAccess<Root: Model>: ModelAccess, @unchecked Sendable {
    let lock = NSRecursiveLock()
    let context: Context<Root>
    var lastState: Root
    var expectedState: Root
    var exhaustivity: Exhaustivity = .full
    var showSkippedAssertions = false
    var valueUpdates: [PartialKeyPath<Root>: ValueUpdate] = [:]
    var events: [Event] = []
    var probes: [TestProbe] = []
    let fileAndLine: FileAndLine

    struct ValueUpdate {
        var apply: (inout Root) -> Void
        var debugInfo: () -> String
    }

    struct Event {
        var event: Any
        var context: AnyContext
    }

    init(model: Root, dependencies: (inout ModelDependencies) -> Void, fileAndLine: FileAndLine) {
        expectedState = model.frozenCopy
        lastState = model.frozenCopy
        self.fileAndLine = fileAndLine
        context = Context(model: model, lock: NSRecursiveLock(), dependencies: dependencies, parent: nil)

        super.init(useWeakReference: true)

        context.readModel._$modelContext.access = self
        context.modifyModel._$modelContext.access = self
        usingAccess(self) {
            context.model.activate()
        }
    }

    override var shouldPropagateToChildren: Bool { true }

    override func willAccess<M: Model, Value>(_ model: M, at path: KeyPath<M, Value>&Sendable) -> (() -> Void)? {
        guard let path = path as? WritableKeyPath<M, Value> else { return nil }
        
        let rootPaths = model.context?.rootPaths.compactMap { $0 as? WritableKeyPath<Root, M> }
        guard let rootPaths else {
            if let assertContext {
                assertContext.modelsNoLongerPartOfTester.append(model.typeDescription)
            } else {
                fail("Model \(model.typeDescription) is no longer part of this tester", at: fileAndLine)
            }
            return nil
        }

        guard let assertContext else { return nil }

        let fullPaths = rootPaths.map { $0.appending(path: path) }

        return {
            let value = frozenCopy(model.context![path])
            for fullPath in fullPaths {
                assertContext.accesses.append(.init(
                    path: fullPath,
                    modelName: model.typeDescription,
                    propertyName: propertyName(from: model, path: path),
                    value: String(customDumping: value)
                ) {
                    $0[keyPath: fullPath] = value
                })
            }
        }
    }

    override func didModify<M: Model, Value>(_ model: M, at path: KeyPath<M, Value>&Sendable) -> (() -> Void)? {
        guard let path = path as? WritableKeyPath<M, Value> else { return nil }

        let rootPaths = model.context?.rootPaths.compactMap { $0 as? WritableKeyPath<Root, M> }
        guard let rootPaths else {
            fatalError()
        }

        let fullPaths = rootPaths.map { $0.appending(path: path) }
        return {
            let value = frozenCopy(model.context![path])

            self.lock {
                for fullPath in fullPaths {
                    self.valueUpdates[fullPath] = .init {
                        $0[keyPath: fullPath] = value
                    } debugInfo: {
                        "\(String(describing: M.self)).\(propertyName(from: model, path: path) ?? "UNKOWN") == \(String(customDumping: value))"
                    }

                    self.lastState[keyPath: fullPath] = value
                }
            }
        }
    }

    override func didSend<M: Model, Event>(event: Event, from context: Context<M>) {
        lock {
            events.append(.init(event: event, context: context))
        }
    }

    func fail(_ message: String, at fileAndLine: FileAndLine) {
        reportIssue(message, fileID: fileAndLine.fileID, filePath: fileAndLine.filePath, line: fileAndLine.line, column: fileAndLine.column)
    }

    func fail(_ message: String, for area: Exhaustivity, at fileAndLine: FileAndLine) {
        if lock({ exhaustivity.contains(area) }) {
            fail(message, at: fileAndLine)
        } else if lock({ showSkippedAssertions }) {
            _XCTExpectFailure {
                fail(message, at: fileAndLine)
            }
        }
    }

    func assert(timeoutNanoseconds timeout: UInt64, at fileAndLine: FileAndLine, predicates: [AssertBuilder.Predicate], enableExhaustionTest: Bool = true) async {
        let context = TesterAssertContext(events: { self.lock { self.events } }, fileAndLine: fileAndLine)
        await TesterAssertContextBase.$assertContext.withValue(context) {

            let start = DispatchTime.now().uptimeNanoseconds
            while true {
                var failures: [TesterAssertContext.Failure] = []
                var passedAccesses: [TesterAssertContext.Access] = []

                context.eventsSent.removeAll()
                context.probes.removeAll()

                for predicate in predicates {
                    context.predicate = predicate
                    
                    context.accesses.removeAll(keepingCapacity: true)
                    context.eventsNotSent.removeAll(keepingCapacity: true)
                    context.modelsNoLongerPartOfTester.removeAll(keepingCapacity: true)

                    let passed = predicate.predicate()
                    let accesses = context.accesses
                    if passed {
                        passedAccesses += accesses
                    } else {
                        failures.append(.init(
                            predicate: predicate,
                            accesses: accesses,
                            events: context.eventsNotSent,
                            modelsNoLongerPartOfTester: context.modelsNoLongerPartOfTester,
                            probes: context.probes
                        ))

                        break
                    }
                }

                if failures.isEmpty {
                    let isEqualIncludingIds = lock {
                        var expected = expectedState.frozenCopy
                        var last = lastState.frozenCopy
                        return threadLocals.withValue(true, at: \.includeInMirror) {
                            passedAccesses.reduce(true) { result, access in
                                access.apply(&expected)
                                access.apply(&last)
                                let e = expected[keyPath: access.path]
                                let a = last[keyPath: access.path]

                                return result && (diff(e, a) == nil)
                            }
                        }
                    }

                    if isEqualIncludingIds {
                        lock {
                            for access in passedAccesses {
                                valueUpdates[access.path] = nil
                                access.apply(&expectedState)
                            }

                            events.remove(atOffsets: context.eventsSent)

                            for (probe, value) in context.probes {
                                probe.consume(value)
                            }

                            if enableExhaustionTest {
                                checkExhaustion(at: fileAndLine, includeUpdates: true)
                            }
                        }

                        return
                    }
                }

                if start.distance(to: DispatchTime.now().uptimeNanoseconds) > timeout {
                    lock {
                        for failure in failures {
                            if let (lhs, rhs) = failure.predicate.values() {
                                let propertyNames = failure.accesses.compactMap { access in
                                    access.propertyName.map { "\(access.modelName).\($0)" }
                                }.joined(separator: ", ")

                                for access in failure.accesses {
                                    access.apply(&expectedState)
                                }

                                let title = "Failed to assert: \(propertyNames)"
                                if let message = diffMessage(expected: rhs, actual: lhs, title: "Failed to assert: \(propertyNames)") {
                                    fail(message, at: failure.predicate.fileAndLine)
                                } else {
                                    fail(title, at: failure.predicate.fileAndLine)
                                }
                            } else {
                                for access in failure.accesses {
                                    let predicate = access.propertyName.map {
                                        "\(access.modelName).\($0) == \(access.value)"
                                    } ?? access.value

                                    fail("Failed to assert: \(predicate)", at: failure.predicate.fileAndLine)

                                    access.apply(&expectedState)
                                }
                            }

                            for event in failure.events {
                                fail("Failed to assert sending of: \(String(customDumping: event.event)) from \(event.context.typeDescription)", at: failure.predicate.fileAndLine)
                            }

                            for modelName in failure.modelsNoLongerPartOfTester {
                                fail("Model \(modelName) is no longer part of this tester", at: fileAndLine)
                            }

                            for (probe, value) in failure.probes {
                                let preTitle = "Failed to assert calling of probe" + (probe.name.map { "\"\($0)\":" } ?? ":")
                                let title = value is NoArgs ? preTitle :
                                    """
                                    \(preTitle)
                                        \(String(customDumping: value))
                                    """

                                if probe.isEmpty {
                                    fail(
                                        """
                                        \(title)

                                        No available probe values
                                        """, at: fileAndLine)
                                } else if probe.count == 1, let message = diffMessage(expected: value, actual: probe.values[0], title: "Probe does not match") {
                                    fail(message, at: fileAndLine)
                                } else {
                                    fail(
                                    """
                                    \(title)

                                    \(probe.count) Available probe values to assert:
                                        \(probe.values.map { String(customDumping: $0) }.joined(separator: "\n\t"))
                                    """, at: fileAndLine)
                                }
                            }

                            if failure.accesses.isEmpty, failure.events.isEmpty, failure.modelsNoLongerPartOfTester.isEmpty, failure.probes.isEmpty {
                                fail("Failed to assert: ", at: failure.predicate.fileAndLine)
                            }
                        }

                        for access in passedAccesses {
                            valueUpdates[access.path] = nil
                            access.apply(&expectedState)
                        }
                        
                        events.remove(atOffsets: context.eventsSent)

                        for (probe, value) in context.probes {
                            probe.consume(value)
                        }
                    }

                    if enableExhaustionTest {
                        checkExhaustion(at: fileAndLine, includeUpdates: false)
                    }
                    return
                }

                await Task.yield()
            }
        }
    }

    func checkExhaustion(at fileAndLine: FileAndLine, includeUpdates: Bool, checkTasks: Bool = false) {
        if checkTasks {
            for info in context.activeTasks {
                fail("Models of type `\(info.modelName)` have \(info.fileAndLines.count) active tasks still running", for: .tasks, at: fileAndLine)

                for fileAndLine in info.fileAndLines {
                    fail("Models of type `\(info.modelName)` have an active task still running", for: .tasks, at: fileAndLine)
                }
            }
        }

        let events = lock { self.events }
        for event in events {
            fail("Event `\(String(customDumping: event.event))` sent from `\(event.context.typeDescription)` was not handled", for: .events, at: fileAndLine)
        }

        let probes = lock { self.probes }
        for probe in probes {
            let name = probe.name.map { "\"\($0)\":" } ?? ""
            for value in probe.values {
                let valueString = value is NoArgs ? "" : " with: \(String(customDumping: value))"
                fail("Failed to assert calling of probe \(name)\(valueString)", for: .probes, at: fileAndLine)
            }
        }

        let (lastAsserted, actual) = lock { (expectedState, lastState) }

        let title = "State not exhausted"
        if let message = diffMessage(expected: lastAsserted, actual: actual, title: title) {
            fail(message, for: .state, at: fileAndLine)
        } else {
            let message = threadLocals.withValue(true, at: \.includeInMirror) {
                diffMessage(expected: lastAsserted, actual: actual, title: title)
            }

            if let message {
                fail(message, for: .state, at: fileAndLine)
            } else if includeUpdates {
                let updateNotHandled = valueUpdates.values.map {
                    $0.debugInfo()
                }

                if !updateNotHandled.isEmpty {
                    fail("""
                        \(title): …

                        Modifications not asserted:

                        \(updateNotHandled.map { $0.indent(by: 4) }.joined(separator: "\n\n"))
                        """, for: .state, at: fileAndLine)
                }
            }
        }

        lock {
            self.expectedState = self.lastState
            self.valueUpdates.removeAll()
        }

    }

    func install(_ probe: TestProbe) {
        lock {
            if probes.contains(where: { $0 === probe }) { return }
            probes.append(probe)
        }
    }

    final class TesterAssertContext: TesterAssertContextBase, @unchecked Sendable {
        let events: () -> [Event]
        let fileAndLine: FileAndLine
        var predicate: AssertBuilder.Predicate?

        struct Access {
            var path: PartialKeyPath<Root>
            var modelName: String
            var propertyName: String?
            var value: String

            var apply: (inout Root) -> Void
        }

        var accesses: [Access] = []
        var eventsSent: IndexSet = []
        var eventsNotSent: [Event] = []
        var modelsNoLongerPartOfTester: [String] = []
        var probes: [(probe: TestProbe, value: Any)] = []

        init(events: @escaping () -> [Event], fileAndLine: FileAndLine) {
            self.events = events
            self.fileAndLine = fileAndLine
        }

        var predicateFileAndLine: FileAndLine { predicate?.fileAndLine ?? fileAndLine }

        struct Failure {
            var predicate: AssertBuilder.Predicate
            var accesses: [Access] = []
            var events: [Event] = []
            var modelsNoLongerPartOfTester: [String] = []
            var probes: [(TestProbe, Any)]
        }

        override func didSend<M: Model, E>(event: E, from context: Context<M>) -> Bool {
            let events = self.events()
            let index = events.indices.firstIndex { i in
                !eventsSent.contains(i) &&
                events[i].context === context &&
                (isEqual(events[i].event, event) ?? (diff(events[i].event, event) == nil))
            }

            guard let index else {
                eventsNotSent.append(Event(event: event, context: context))
                return false
            }

            eventsSent.insert(index)
            return true
        }

        override func probe(_ probe: TestProbe, wasCalledWith value: Any) -> Void {
            probes.append((probe, value))
        }
    }

    var assertContext: TesterAssertContext? {
        TesterAssertContextBase.assertContext as? TesterAssertContext
    }
}

class TesterAssertContextBase: @unchecked Sendable {
    func didSend<M: Model, Event>(event: Event, from context: Context<M>) -> Bool { fatalError() }
    func probe(_ probe: TestProbe, wasCalledWith value: Any) -> Void { fatalError() }

    @TaskLocal static var assertContext: TesterAssertContextBase?
}
