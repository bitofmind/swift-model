// swift-tools-version:6.0
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
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.9.0"),
        // Pin below 1.1.0: that version introduced a trait-based OpenCombine shim that breaks
        // Android cross-compilation (the trait is only auto-enabled based on the host OS, not
        // the target). 1.0.x properly guards all Combine code with #if canImport(Combine).
        // Package.resolved is not tracked in git, so this pin is required to prevent CI from
        // resolving a newer version via swift-clocks's transitive dependency.
        .package(url: "https://github.com/pointfreeco/combine-schedulers", "1.0.0"..<"1.1.0"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.3"),
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
