import Testing
@testable import SwiftModel

// Regression coverage for storing existentials (`any P`, `Any`, structs wrapping them) in a
// `@Model`, in particular when a user-written `init` assigns them in its body.
//
// History: a user-written init used to materialise `_State` in Swift's phase-1 init, before
// the body ran, padding every not-yet-assigned property with `_zeroInit()` (a raw memset).
// For an opaque existential the zero bytes are a null metadata pointer and the placeholder
// crashed the process on its first copy. `_State` is now built only once every required
// property has been assigned, so no placeholder value exists at all.

private protocol Service: Sendable { func name() -> String }
private struct ServiceA: Service { func name() -> String { "A" } }
private struct ServiceB: Service { func name() -> String { "B" } }
private protocol ClassService: AnyObject, Sendable { func name() -> String }
private final class ClassServiceImpl: ClassService { func name() -> String { "class" } }

private struct Wrapper: Sendable {
    var service: any Service
    var label: String
}

@Model private struct Memberwise: Sendable {
    var service: any Service
}

@Model private struct UserInit: Sendable {
    var service: any Service
    var count = 0
    init(service: any Service) { self.service = service }
}

@Model private struct UserInitDefault: Sendable {
    var service: any Service = ServiceA()
    init(service: any Service) { self.service = service }
}

@Model private struct UserInitOptional: Sendable {
    var service: (any Service)?
    init(service: any Service) { self.service = service }
}

@Model private struct UserInitClassBound: Sendable {
    var service: any ClassService
    init(service: any ClassService) { self.service = service }
}

@Model private struct UserInitAny: Sendable {
    var payload: Any
    init(payload: Any) { self.payload = payload }
}

@Model private struct UserInitWrapped: Sendable {
    var wrapper: Wrapper
    init(wrapper: Wrapper) { self.wrapper = wrapper }
}

@Model private struct Child: Sendable {
    var service: any Service
    var value = 0
    init(service: any Service) { self.service = service }
}

/// Several required properties assigned out of declaration order, with reads of already
/// assigned properties, in-place mutations, a child `@Model`, a collection, and a
/// `didSet` property all happening in the body *before* the last required assignment.
@Model private struct Busy: Sendable {
    var first: any Service
    var child: Child
    var items: [String]
    var last: any Service
    var counter = 0
    var log: [String] = []
    var observed: Int = 0 {
        didSet { log.append("observed:\(observed)") }
    }

    init(first: any Service, last: any Service) {
        self.items = ["x"]
        self.child = Child(service: first)
        self.first = first
        counter += 1                 // in-place mutation of a defaulted property
        items.append(self.first.name())  // in-place mutation of an assigned required property
        child.value = items.count    // in-place mutation through a required child model
        observed = counter + 1       // didSet property assigned in the body (observer does not
                                     // fire pre-anchor, matching Swift's stored-property rule)
        self.last = last             // completes the frame
        counter += 10                // mutation after materialisation
    }
}

@Suite(.modelTesting)
struct ExistentialPropertyTests {
    @Test func memberwiseInit() async {
        let m = Memberwise(service: ServiceA()).withAnchor()
        await expect(m.service.name() == "A")
        m.service = ServiceB()
        await expect(m.service.name() == "B")
    }

    @Test func userWrittenInitAssigningRequiredExistential() async {
        let m = UserInit(service: ServiceA()).withAnchor()
        await expect(m.service.name() == "A")
        await expect(m.count == 0)
        m.service = ServiceB()
        await expect(m.service.name() == "B")
        m.count += 1
        await expect(m.count == 1)
    }

    @Test func userWrittenInitWithDefaultedExistential() async {
        let m = UserInitDefault(service: ServiceB()).withAnchor()
        await expect(m.service.name() == "B")
    }

    // One anchored root per test: a scope tracks exactly one tree, so these four shapes
    // get a test each rather than sharing a scope.

    @Test func optionalExistential() async {
        let m = UserInitOptional(service: ServiceA()).withAnchor()
        await expect(m.service?.name() == "A")
    }

    @Test func classBoundExistential() async {
        let m = UserInitClassBound(service: ClassServiceImpl()).withAnchor()
        await expect(m.service.name() == "class")
    }

    @Test func anyPayload() async {
        let m = UserInitAny(payload: 42).withAnchor()
        await expect(m.payload as? Int == 42)
    }

    @Test func existentialWrappedInStruct() async {
        let m = UserInitWrapped(wrapper: Wrapper(service: ServiceB(), label: "w")).withAnchor()
        await expect {
            m.wrapper.service.name() == "B"
            m.wrapper.label == "w"
        }
    }

    @Test func initBodyCanReadAndMutateBeforeFrameIsComplete() async {
        let m = Busy(first: ServiceA(), last: ServiceB()).withAnchor()
        await expect(m.first.name() == "A")
        await expect(m.last.name() == "B")
        await expect(m.items == ["x", "A"])
        await expect(m.child.service.name() == "A")
        await expect(m.child.value == 2)
        await expect(m.counter == 11)
        await expect(m.observed == 2)
        await expect(m.log.isEmpty)
        m.observed = 5
        await expect {
            m.observed == 5
            m.log == ["observed:5"]
        }
    }

    @Test func preAnchorValuesSurviveCopiesAndAnchoring() async {
        let unanchored = UserInit(service: ServiceA())
        #expect(unanchored.service.name() == "A")
        let copy = unanchored
        let m = copy.withAnchor()
        await expect(m.service.name() == "A")
        let frozen = m.frozenCopy
        #expect(frozen.service.name() == "A")
    }
}
