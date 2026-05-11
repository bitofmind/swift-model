// swift-tools-version:6.1
// Bumped from 6.0 to 6.1 to use the `traits:` parameter on `.package(...)`. We override
// swift-dependencies' default traits to `["Clocks", "Foundation"]` (turning off
// `CombineSchedulers`, which we don't use and which pulls in an Android-incompatible
// OpenCombine shim ≥ 1.1.0). The `traits:` parameter doesn't exist pre-6.1, hence
// the bump.
//
// SE-0152 note: swift-dependencies ships `Package@swift-6.0.swift` (no traits) alongside
// its `Package.swift` (tools-version 6.3, declares traits). SwiftPM selects the manifest
// whose tools-version is the highest value ≤ the current compiler version. Any compiler
// < 6.3 picks the 6.0 shadow and sees no traits, making our override a hard error.
// CI therefore requires Swift 6.3+ on all platforms (see `.github/workflows/ci.yml`).
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
        // Tracking pointfreeco/main until a release ≥ #406 is tagged — that PR introduces
        // package traits for `Clocks`, `CombineSchedulers`, and `Foundation` (defaults: all on).
        // We override to enable only `Clocks` so swift-dependencies' `URLSession.swift` and
        // `CombineSchedulers` product are dropped from the `Dependencies` target. Saves
        // ~16 MB of `libFoundationNetworking.so` for Android consumers.
        // Switch back to `from: "X.Y.Z"` once tagged.
        .package(url: "https://github.com/pointfreeco/swift-dependencies", branch: "main", traits: ["Clocks", "Foundation"]),
        // Combine-schedulers stays in the resolution graph (swift-dependencies declares it
        // unconditionally as a package-level dep) but is NOT linked into anything we use,
        // because the `CombineSchedulers` trait is off above. The 1.0.0..<1.1.0 pin from
        // before #406 is therefore no longer load-bearing for Android — keep it for now
        // as belt-and-braces; safe to relax once the new wiring is verified on CI.
        .package(url: "https://github.com/pointfreeco/combine-schedulers", "1.0.0"..<"1.1.0"),
        // Fork branch with the `Networking` package trait gating the FoundationNetworking
        // import and the two FoundationNetworking-typed CustomDump conformances
        // (`NSURLRequest: CustomDumpRepresentable`, `URLRequest.NetworkServiceType:
        // CustomDumpStringConvertible`). Default-on, we override to `traits: []` to skip
        // them — saves ~16 MB `libFoundationNetworking.so` from Android cross-compile
        // consumers' bridge `DT_NEEDED`. Switch back to the upstream
        // `pointfreeco/swift-custom-dump` once the Networking trait is merged + tagged.
        .package(url: "https://github.com/mansbernhardt/swift-custom-dump", branch: "android-support", traits: []),
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
                .product(name: "InlineSnapshotTesting", package: "swift-snapshot-testing", condition: .when(platforms: [.macOS, .linux])),
                .product(name: "Clocks", package: "swift-clocks"),
                .product(name: "IssueReportingTestSupport", package: "xctest-dynamic-overlay"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
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
