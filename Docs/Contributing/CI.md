# CI

Contributor notes on the GitHub Actions setup (`.github/workflows/ci.yml`). Read when a CI job fails or when changing the workflow, `Package.swift` platform conditions or `scripts/ci-test`.

GitHub Actions (`.github/workflows/ci.yml`):
- **macOS** (matrix: `parallel` | `serial`): `macos-15`, default Xcode, `swift test`.
- **macOS (TSan)**: full parallel suite under `--sanitize=thread` at `SWIFT_MODEL_TIMEOUT_SCALE=6`;
  fails on ANY `WARNING: ThreadSanitizer` in the log (TSan doesn't fail the exit code itself).
  Skips the one documented-unsupported interop test
  (`testObservedStreamWithModelAccessingObservable`, which races by design in test code).
  The suite has been TSan-clean since the 2026-07-02 concurrency-audit fixes — any report is a
  regression.
- **Linux** (matrix: `parallel` | `serial`): `ubuntu-latest`, `swift:6.3.0` container, `scripts/ci-test` (wraps `swift test` — see below).
- **Android**: compile-only cross-compile to `aarch64-unknown-linux-android28`.
- **WASM**: build (no run) to `wasm32-unknown-wasip1` — the library on its own,
  plus `--build-tests`, which links a full test executable. The link step needs
  `OMIT_DYNAMIC_TEST_SUPPORT=1` (xctest-dynamic-overlay ≥ 1.11.0, hence the
  `from: "1.11.0"` floor): WASI has no shared libraries, and without the lever
  SwiftPM materialises the `type: .dynamic` `IssueReportingTestSupport` product
  into the test build plan regardless of platform conditions. It also needs
  `SWIFTPM_TARGET_WASI=1`, which trims the package to `SwiftModel` /
  `SwiftModelMacros` / `SwiftModelTests` — `--build-tests` builds *every* target,
  and `SwiftModelBenchmarks` doesn't compile for WASI (`DispatchTime`,
  `DispatchQueue.concurrentPerform`). Running the bundle under wasmtime is still
  open — `GlobalTickScheduler` is GCD-backed and would need a WASI-native path
  first.

**Linux `swift test` goes through `scripts/ci-test`.** On Linux, swift-syntax's
compiler-plugin message handler intermittently logs `Internal Error:
DecodingError … Corrupted JSON … unexpected end of file` during macro expansion
(a truncated/EOF frame on the compiler ↔ macro-plugin IPC pipe). It is emitted
on essentially every Linux build — present in passing runs too — but can
occasionally make `swift test` exit non-zero even though the build compiled and
every test passed (this is how `Linux (parallel)` flaked on run 28446231009).
It's an upstream toolchain artifact, not a SwiftModel/macro-plugin bug. The
wrapper treats "build compiled + `Test run with … passed` + zero real failures"
as success and still fails hard on any genuine test/build failure — it does
**not** retry or mask real failures (a failing/flaky test, or a real build
error, still fails the job). macOS is unaffected (zero occurrences) and calls
`swift test` directly.

Both `parallel` and `serial` test modes run for macOS and Linux, with the
executor-drive as the unconditional default (no flag — see `_makeTestExecutorBox`),
and **both are now REQUIRED** (merge-blocking). Serial is the deterministic
regression gate (caught the OR-path race fixed in 497c2ab). Parallel validates
the framework's parallel-test claim; it was informational while a small
`waitUntil`-based tail flaked on the small CI runners (`testSharedDependency`, the
unsupported `testObservedStream`), but both causes are fixed (see
`Docs/test-determinism-executor-drain.md` Updates 22–24) and it has been verified
green across repeated runs. `fail-fast: false` so one mode's flake doesn't
suppress the other's signal.


`swift-tools-version` is **6.1** — minimum required for the `traits:` parameter
on `.package(...)`, used by the `swift-custom-dump` fork dependency. Pre-6.1
Swift toolchains can't read this manifest.
