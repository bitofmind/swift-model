import Foundation

/// Per-test configuration knobs read by both the `@Test(.modelTesting)` trait
/// machinery and the always-available test-infrastructure helpers (`expect`,
/// `settle`'s `waitUntilSettled`, `waitUntil`).
///
/// **Lives in `Internal/` (not `Testing/`) deliberately**: this enum is
/// referenced from `TestExpect.swift`, `TestWaitSupport.swift`, and
/// `WaitUntilCallback.swift` — files that must compile on every platform.
/// `Testing/ModelTestingTrait.swift` is fenced with
/// `#if canImport(Testing) && !os(Android)` because it imports `Testing`;
/// putting the options enum there would make any non-trait reference fail to
/// compile on Android / WASM.
enum ModelTestingTraitOptions {
    /// Multiplier applied to all test-infrastructure timeout defaults:
    /// `expect`'s budget, `settle`'s in-test and cleanup budgets, the
    /// per-test wall-clock cap, the safety-net meta-test bounds, and every
    /// `waitUntil` call (default and explicit timeouts both scale).
    ///
    /// Default `1.0` is tuned for a developer machine where the cooperative
    /// pool serves tasks within milliseconds. On slow CI runners
    /// (2-3 vCPU GitHub Actions images, container-based Linux jobs)
    /// `.deferential` callbacks routinely take seconds to be scheduled
    /// even when the model is genuinely quiet; bump this to 2–4 on CI so
    /// the safety-net budgets don't fire as load symptoms.
    ///
    /// Override via `SWIFT_MODEL_TIMEOUT_SCALE` env var (positive float).
    /// We deliberately keep this as a single knob — both budgets and
    /// meta-test bounds scale together, so a stuck test still fails in
    /// roughly the same fraction of budget as a healthy test would
    /// complete in.
    static var timeoutScale: Double {
        if let envValue = ProcessInfo.processInfo.environment["SWIFT_MODEL_TIMEOUT_SCALE"],
           let parsed = Double(envValue), parsed > 0 {
            return parsed
        }
        return 1.0
    }

    /// Wall-clock cap on a single `@Test(.modelTesting)`'s body + checkExhaustion.
    /// Generous default — correct tests complete in milliseconds even under
    /// heavy saturation. Hitting this cap surfaces a real bug.
    ///
    /// Scaled by `timeoutScale`. Override the absolute value via
    /// `SWIFT_MODEL_TEST_TIMEOUT` env var (seconds, float) — takes
    /// precedence over the scaled default.
    static var testWallClockSeconds: Double {
        if let envValue = ProcessInfo.processInfo.environment["SWIFT_MODEL_TEST_TIMEOUT"],
           let parsed = Double(envValue), parsed > 0 {
            return parsed
        }
        return 30 * timeoutScale
    }
}
