// swift-tools-version:6.1
// A tiny executable that exercises SwiftModel under wasm32 at runtime. The test suite
// itself can't run on WASI yet (see Docs/Contributing/CI.md), so this covers the code paths
// that have broken there before. Run it with `scripts/wasm-smoke`.
import PackageDescription

// A path dependency's identity is its directory name, which isn't `swift-model` in a worktree.
// Plain string handling rather than Foundation, which doesn't load in every toolchain's manifest.
let repoComponents = #filePath.split(separator: "/").dropLast(3)
let repoPath = "/" + repoComponents.joined(separator: "/")
let repoName = String(repoComponents.last!)

let package = Package(
    name: "WASMSmoke",
    dependencies: [
        .package(path: repoPath),
    ],
    targets: [
        .executableTarget(
            name: "WASMSmoke",
            dependencies: [
                .product(name: "SwiftModel", package: repoName),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
