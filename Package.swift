// swift-tools-version:6.1
// Bumped from 6.0 to 6.1 for the `traits:` parameter on `.package(...)`, used by
// swift-custom-dump below. swift-dependencies does NOT use traits here — it still ships
// a `Package@swift-6.0.swift` shadow manifest that SE-0152 always selects over the
// traits-aware `Package.swift`; any `traits:` override would be a hard error.
import PackageDescription
import CompilerPluginSupport

#if swift(>=6.2)
let defaultIsolationTargets: [Target] = [
    .testTarget(
        name: "SwiftModelMainActorTests",
        dependencies: [
            "SwiftModel",
            .product(name: "Dependencies", package: "swift-dependencies"),
            .product(name: "IssueReportingTestSupport", package: "xctest-dynamic-overlay"),
        ],
        swiftSettings: [
            .unsafeFlags(["-default-isolation", "MainActor"])
        ]
    )
]
#else
let defaultIsolationTargets: [Target] = []
#endif

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
        // Tracking pointfreeco/main until a release ≥ PR #406 is tagged. The
        // `Package@swift-6.0.swift` shadow manifest that previously blocked
        // consumer-set traits has been dropped from `main` — we can now disable
        // the default-on `CombineSchedulers` trait explicitly. We only request
        // `Foundation` + `Clocks`; omitting `CombineSchedulers` drops the
        // transitive `combine-schedulers` dep, which is what was blocking the
        // WASM build (its `Internal/Lock.swift` uses `pthread_mutex_destroy`,
        // not available in the WASI SDK).
        .package(
            url: "https://github.com/pointfreeco/swift-dependencies",
            branch: "main",
            traits: ["Foundation", "Clocks"]
        ),
        // Fork pinned at the revision that gates the FoundationNetworking import and the
        // two FoundationNetworking-typed CustomDump conformances (`NSURLRequest:
        // CustomDumpRepresentable`, `URLRequest.NetworkServiceType:
        // CustomDumpStringConvertible`) behind a package trait. Default-on, we override
        // to `traits: []` to skip them — saves ~16 MB `libFoundationNetworking.so` from
        // Android cross-compile consumers' bridge `DT_NEEDED`.
        //
        // We pin to an explicit revision rather than `branch: "android-support"` because:
        //   1. `swift-snapshot-testing` brings in `swift-custom-dump` via the upstream
        //      URL without specifying traits. SwiftPM resolves the two URLs to a single
        //      package identity (`swift-custom-dump`) and *unions* the requested traits
        //      across consumers, so snapshot-testing's default-on `FoundationNetworking`
        //      trait wins — our `traits: []` is effectively a no-op until the upstream
        //      PR is merged + tagged.
        //   2. With the trait effectively forced-on, the only thing keeping WASM (which
        //      has no `URLRequest`) compiling was the `#if !os(WASI)` source guard. The
        //      PR-review cycle on the fork's `android-support` branch dropped that guard
        //      in favour of relying purely on the (unioned-on) trait gate. Newer
        //      revisions therefore break WASM builds.
        //
        // 0fc8018b2903e6ce471eb458ab23f8fc0ba6fdf6 is the latest commit on the
        // fork's PR branch (pointfreeco/swift-custom-dump#164). Keeps the
        // `#if !os(WASI)` guard and the trait-gated `FoundationNetworking`
        // import; the trait name matches what upstream `swift-snapshot-testing`
        // now expects (`FoundationNetworking`, not the old `Networking`), so
        // SwiftPM's identity-unification of the two `swift-custom-dump`
        // references resolves cleanly. Bump when the upstream PR merges and the
        // fork can be retired in favour of a tagged `pointfreeco/` release.
        .package(
            url: "https://github.com/mansbernhardt/swift-custom-dump",
            revision: "0fc8018b2903e6ce471eb458ab23f8fc0ba6fdf6",
            traits: []
        ),
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
                .product(name: "IssueReportingTestSupport", package: "xctest-dynamic-overlay"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
            ]
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
                .product(name: "IssueReportingTestSupport", package: "xctest-dynamic-overlay"),
            ]
        ),
        .testTarget(
            name: "SwiftModelSnapshotTests",
            dependencies: [
                "SwiftModel",
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "InlineSnapshotTesting", package: "swift-snapshot-testing", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "Clocks", package: "swift-clocks"),
                .product(name: "IssueReportingTestSupport", package: "xctest-dynamic-overlay"),
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
    ] + defaultIsolationTargets,
    swiftLanguageModes: [.v6]
)
