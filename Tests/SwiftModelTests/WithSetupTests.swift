import Testing
import ConcurrencyExtras
@testable import SwiftModel
import SwiftModel

// MARK: - Keys

private extension EnvironmentKeys {
    var setupFlag: EnvironmentStorage<Bool> { .init(defaultValue: false) }
    var setupValue: EnvironmentStorage<String> { .init(defaultValue: "") }
}

private extension LocalKeys {
    var localSetupFlag: LocalStorage<Bool> { .init(defaultValue: false) }
}

// MARK: - Models

@Model
private struct SetupOrderModel {
    var log: [String] = []

    func onActivate() {
        log.append("onActivate")
    }
}

@Model
private struct SetupEnvModel {
    var activatedWithFlag = false

    func onActivate() {
        activatedWithFlag = node.environment.setupFlag
    }
}

@Model
private struct SetupLocalModel {
    var activatedWithFlag = false

    func onActivate() {
        activatedWithFlag = node.local.localSetupFlag
    }
}

@Model
private struct SetupGuardModel {
    var taskStarted = false

    func onActivate() {
        guard node.environment.setupFlag else { return }
        node.task {
            taskStarted = true
        }
    }
}

// MARK: - WithSetupTests

@Suite(.modelTesting)
struct WithSetupTests {

    // withSetup runs before onActivate, withActivation runs after.
    @Test func orderingIsSetupThenOnActivateThenActivation() async {
        let model = SetupOrderModel()
            .withSetup { $0.log.append("withSetup") }
            .withActivation { $0.log.append("withActivation") }
            .withAnchor()
        await settle()
        #expect(model.log == ["withSetup", "onActivate", "withActivation"])
    }

    // Multiple withSetup calls are additive and run in declaration order.
    @Test func multipleSetupClosuresRunInOrder() async {
        let model = SetupOrderModel()
            .withSetup { $0.log.append("setup1") }
            .withSetup { $0.log.append("setup2") }
            .withAnchor()
        await settle()
        #expect(model.log == ["setup1", "setup2", "onActivate"])
    }

    // An environment key set in withSetup is visible inside onActivate.
    @Test func environmentKeySetInSetupIsVisibleInOnActivate() async {
        let model = SetupEnvModel()
            .withSetup { $0.node.environment.setupFlag = true }
            .withAnchor()
        await settle()
        #expect(model.activatedWithFlag == true)
    }

    // Default value (false) is seen when withSetup does not set the key.
    @Test func environmentKeyDefaultUsedWhenSetupAbsent() async {
        let model = SetupEnvModel().withAnchor()
        await settle()
        #expect(model.activatedWithFlag == false)
    }

    // A local key set in withSetup is visible inside onActivate.
    @Test func localKeySetInSetupIsVisibleInOnActivate() async {
        let model = SetupLocalModel()
            .withSetup { $0.node.local.localSetupFlag = true }
            .withAnchor()
        await settle()
        #expect(model.activatedWithFlag == true)
    }

    // Without withSetup the guard in onActivate prevents the task from starting.
    @Test func guardSkipsTaskWhenSetupKeyAbsent() async {
        let model = SetupGuardModel().withAnchor()
        await settle()
        #expect(!model.taskStarted)
    }

    // With withSetup setting the flag the guard passes and the task starts.
    @Test func guardRunsTaskWhenSetupKeyPresent() async {
        let model = SetupGuardModel()
            .withSetup { $0.node.environment.setupFlag = true }
            .withAnchor()
        // settle() waits for the activation task and resets activation-phase exhaustivity.
        await settle()
        #expect(model.taskStarted)
    }

    // withSetup closure is never called if the model is never anchored.
    @Test func setupClosureNotCalledIfNotAnchored() {
        var called = false
        _ = SetupOrderModel().withSetup { _ in called = true }
        #expect(called == false)
    }
}
