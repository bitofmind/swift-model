// swift-tools-version:6.1
// Bumped from 6.0 to 6.1 for the `traits:` parameter on `.package(...)`, used by
// swift-custom-dump below (unconditionally) and swift-dependencies (only on
// `swift(>=6.3)` — see the gate further down). swift-dependencies can't take an
// unconditional `traits:` override: it still ships a `Package@swift-6.0.swift`
// shadow manifest that SE-0152 selects on toolchains < 6.3 over the traits-aware
// `Package.swift`, and that shadow declares no traits — so a `traits:` override
// against it is a hard error.
import Foundation
import PackageDescription
import CompilerPluginSupport

// Build the `swift-dependencies` package dependency separately so the
// `#if swift(>=6.3)` directive sits at statement scope. PackageDescription's
// array-literal parser does NOT accept `#if` directives between elements —
// the CI manifest compile errors with "expected expression in container
// literal" when we try.
//
// We'd like to disable the default-on `CombineSchedulers` trait — its
// transitive `combine-schedulers` dep uses `pthread_mutex_destroy`, which is
// unavailable in the WASI SDK and breaks the WASM build. Setting
// `traits: ["Foundation", "Clocks"]` does that — but only on toolchains that
// pick swift-dependencies' tools-version-6.3 `Package.swift` (which declares
// `traits`). Per SE-0152, toolchains < 6.3 instead pick the
// `Package@swift-6.0.swift` shadow manifest, which declares no traits — and
// SwiftPM errors out when a consumer sets traits on a package whose selected
// manifest declares none.
//
// Concretely: macOS CI (Xcode 26.3 → Swift 6.2) picks the shadow and would
// error; Linux / Android / WASM CI (swift:6.3.0 container) pick the
// trait-aware manifest. Gate the `traits:` parameter on `swift(>=6.3)` so we
// only request traits where the selected manifest actually declares them.
// On older toolchains we fall back to default traits — CombineSchedulers is
// pulled in, which is harmless on macOS/iOS (the dep builds fine there).
// The WASM job uses 6.3, so it still gets the trait-gated,
// CombineSchedulers-free tree.
//
// swift-dependencies 1.13.0 shipped the trait-aware manifest (PR #406), so we
// now pin a tagged release instead of `main`. The `#if swift(>=6.3)` gate must
// stay, though: 1.13.0 STILL ships the `Package@swift-6.0.swift` shadow
// manifest (no traits, unconditional CombineSchedulers), which SE-0152 selects
// on toolchains < 6.3 — setting `traits:` against that manifest is a hard
// error. Retire this `#if` only once swift-dependencies drops the shadow
// manifest and cuts a tag without it.
#if swift(>=6.3)
let swiftDependenciesPackage: Package.Dependency = .package(
    url: "https://github.com/pointfreeco/swift-dependencies",
    from: "1.13.0",
    traits: ["Foundation", "Clocks"]
)
#else
let swiftDependenciesPackage: Package.Dependency = .package(
    url: "https://github.com/pointfreeco/swift-dependencies",
    from: "1.13.0"
)
#endif

#if swift(>=6.2)
let defaultIsolationTargets: [Target] = [
    .testTarget(
        name: "SwiftModelMainActorTests",
        dependencies: [
            "SwiftModel",
            .product(name: "Dependencies", package: "swift-dependencies"),
            // See SwiftModelTests for WASI exclusion rationale.
            .product(
                name: "IssueReportingTestSupport",
                package: "xctest-dynamic-overlay",
                condition: .when(platforms: [.macOS, .linux, .iOS, .tvOS, .watchOS, .macCatalyst, .android])
            ),
        ],
        swiftSettings: [
            .unsafeFlags(["-default-isolation", "MainActor"])
        ]
    )
]
#else
let defaultIsolationTargets: [Target] = []
#endif

// When `SWIFTPM_TARGET_WASI=1` is set in the environment, the manifest drops
// every test target except `SwiftModelTests`. This is the WASM CI's "run only
// the main test target" lever.
//
// Why we need it: WASI doesn't support dynamic libraries, and
// `IssueReportingTestSupport` is a `type:.dynamic` SwiftPM product. We
// platform-condition the dep out of all five test targets (search this file
// for `IssueReportingTestSupport`), but the `swift test` test-executable link
// still tried to build `libIssueReportingTestSupport.wasm` regardless —
// SwiftPM seems to materialise the product whenever ANY consumer in the
// resolved graph references it, even via a platform-failed condition. Until
// we figure out exactly what triggers that, physically removing the
// non-essential test targets when targeting WASI is the surest way to keep
// the dynamic product out of the link plan.
//
// The Snapshot / Benchmark / MainActor / Macro tests don't add platform
// coverage that the main SwiftModelTests suite doesn't already provide for
// WASM. They stay enabled on every other platform.
let isWasiBuild = ProcessInfo.processInfo.environment["SWIFTPM_TARGET_WASI"] == "1"

let package = Package(
    name: "swift-model",
    platforms: [.macOS(.v11), .iOS(.v14), .tvOS(.v14), .watchOS(.v6), .macCatalyst(.v13)],
    products: [
        .library(
            name: "SwiftModel",
            targets: ["SwiftModel"]
        ),
    ],
    dependencies: [
        // Declared at file scope (search for `swiftDependenciesPackage`) so the
        // `#if swift(>=6.3)` gate around its `traits:` parameter sits outside
        // the array literal — PackageDescription rejects `#if` directives
        // between array elements.
        swiftDependenciesPackage,
        // swift-custom-dump 1.6.0 (2026-05-26) shipped the
        // `#if FoundationNetworking && canImport(FoundationNetworking)` guards
        // we previously carried on a fork (pointfreeco/swift-custom-dump#164).
        // The `canImport` arm keeps WASM (no `FoundationNetworking` module)
        // and Android (no module unless the bridge pulls it) compiling, and
        // `swift-snapshot-testing` already unions the `FoundationNetworking`
        // trait on across the shared `swift-custom-dump` identity — so a plain
        // version pin resolves cleanly. (History: the fork existed only because
        // upstream hadn't tagged the fix yet.)
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.6.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "600.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-macro-testing", from: "0.6.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.6"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.1.0"),
        .package(url: "https://github.com/pointfreeco/swift-identified-collections", from: "1.1.0"), // Used by SwiftModelBenchmarks only
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", from: "1.9.0"),
        .package(url: "https://github.com/pointfreeco/swift-clocks", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    ],
    targets: [
        .target(name: "SwiftModel", dependencies: [
            "SwiftModelMacros",
            .product(name: "Dependencies", package: "swift-dependencies"),
            .product(name: "CustomDump", package: "swift-custom-dump"),
            .product(name: "OrderedCollections", package: "swift-collections"),
            .product(name: "IssueReporting", package: "xctest-dynamic-overlay"),
        ]),
        .testTarget(
            name: "SwiftModelTests",
            dependencies: [
                "SwiftModel",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "Clocks", package: "swift-clocks"),
                // `IssueReportingTestSupport` is a `type:.dynamic` product. WASI
                // (the WASM SDK target triple `wasm32-unknown-wasip1`) has no
                // shared-library / dlopen support, so SwiftPM refuses to link
                // dynamic products. List the platforms that DO support it
                // explicitly; WASI is excluded by omission. On WASI,
                // `reportIssue(...)` calls fall back to the runtime-warning
                // reporter; the `WASIBridgeIssueReporter` in `Utilities.swift`
                // re-registers as a swift-testing-bound reporter at process
                // startup so failures still surface as `Issue.record(...)`.
                .product(
                    name: "IssueReportingTestSupport",
                    package: "xctest-dynamic-overlay",
                    condition: .when(platforms: [.macOS, .linux, .iOS, .tvOS, .watchOS, .macCatalyst, .android])
                ),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
            ],
            exclude: ["TESTING.md"]
        ),
        // Split off from `SwiftModelTests` so we can:
        //   • Skip these on regular CI runs by simply not naming the target (instead
        //     of `--skip Foo --skip Bar` per file).
        //   • Run the snapshot / benchmark suites in isolation when iterating on them.
        //   • Compile-check more of the test surface on platforms that can't host
        //     `InlineSnapshotTesting` (Apple-only types) — those constraints are now
        //     contained in `SwiftModelSnapshotTests` only.
        .testTarget(
            name: "SwiftModelBenchmarkTests",
            dependencies: [
                "SwiftModel",
                .product(name: "Dependencies", package: "swift-dependencies"),
                // See SwiftModelTests for WASI exclusion rationale.
                .product(
                    name: "IssueReportingTestSupport",
                    package: "xctest-dynamic-overlay",
                    condition: .when(platforms: [.macOS, .linux, .iOS, .tvOS, .watchOS, .macCatalyst, .android])
                ),
            ]
        ),
        .testTarget(
            name: "SwiftModelSnapshotTests",
            dependencies: [
                "SwiftModel",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "InlineSnapshotTesting", package: "swift-snapshot-testing", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "Clocks", package: "swift-clocks"),
                // See SwiftModelTests for WASI exclusion rationale.
                .product(
                    name: "IssueReportingTestSupport",
                    package: "xctest-dynamic-overlay",
                    condition: .when(platforms: [.macOS, .linux, .iOS, .tvOS, .watchOS, .macCatalyst, .android])
                ),
            ]
        ),
        .macro(
            name: "SwiftModelMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ]
        ),
        .executableTarget(
            name: "SwiftModelBenchmarks",
            dependencies: [
                "SwiftModel",
                .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
                // `Dependencies` is needed by Benchmarks.swift to declare a custom
                // `BenchDepKey: DependencyKey` for the trait-independent dep-override
                // benchmark — see the comment block at the top of Benchmarks.swift.
                .product(name: "Dependencies", package: "swift-dependencies"),
            ],
            path: "Sources/SwiftModelBenchmarks"
        ),
        .testTarget(
            name: "SwiftModelMacroTests",
            dependencies: [
                // SwiftModelMacros is a host-only macro target. Its test dependencies are
                // guarded here so that SwiftModelMacroTests can be compiled for cross-compilation
                // targets (like Android) as an empty stub. Source files use
                // #if canImport(SwiftModelMacros) to gate all real test code.
                .target(name: "SwiftModelMacros", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "MacroTesting", package: "swift-macro-testing", condition: .when(platforms: [.macOS, .linux])),
            ]
        ),
    ] + (isWasiBuild ? [] : defaultIsolationTargets),
    swiftLanguageModes: [.v6]
)

// On WASI we want only `SwiftModelTests` linked into the test executable;
// every other test target pulls in `IssueReportingTestSupport` (via direct
// dep, MacroTesting, or InlineSnapshotTesting) — that's a `type:.dynamic`
// SwiftPM product, and WASI's linker rejects dynamic libraries. Conditioning
// the individual product deps with `.when(platforms:)` doesn't actually keep
// the dynamic library out of the package test-executable link (something in
// the resolved graph still materialises it). Physically removing the test
// targets is the surest way to stop the dynamic product from being built.
//
// Keep:
//   • `SwiftModel`            — the library under test
//   • `SwiftModelMacros`      — host-built macro plugin (`@Model` expansion)
//   • `SwiftModelTests`       — the test target we actually want to run
//   • `SwiftModelBenchmarks`  — executable, unrelated to the test-link issue
if isWasiBuild {
    package.targets.removeAll { target in
        target.name == "SwiftModelBenchmarkTests"
            || target.name == "SwiftModelSnapshotTests"
            || target.name == "SwiftModelMacroTests"
    }
}
