// swift-tools-version: 5.9
import PackageDescription
import CompilerPluginSupport

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
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.3.7"),
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "509.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-macro-testing", from: "0.2.2"),
        .package(url: "https://github.com/pointfreeco/swift-identified-collections", from: "1.0.0"),
    ],
    targets: [
        .target(name: "SwiftModel", dependencies: [
            "SwiftModelMacros",
            .product(name: "Dependencies", package: "swift-dependencies"),
            .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            .product(name: "CustomDump", package: "swift-custom-dump"),
            .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
        ]),
        .testTarget(
            name: "SwiftModelTests",
            dependencies: [
                "SwiftModel",
                .product(name: "Dependencies", package: "swift-dependencies"),
            ]
        ),
        .macro(
            name: "SwiftModelMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ]
        ),
        .testTarget(
            name: "SwiftModelMacroTests",
            dependencies: [
                "SwiftModelMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "MacroTesting", package: "swift-macro-testing")
            ]
        ),
    ]
)

//for target in package.targets where target.type != .system {
//    target.swiftSettings = target.swiftSettings ?? []
//    target.swiftSettings?.append(
//        .unsafeFlags([
//            "-Xfrontend", "-warn-concurrency",
//            "-Xfrontend", "-enable-actor-data-race-checks",
//        ])
//    )
//}
