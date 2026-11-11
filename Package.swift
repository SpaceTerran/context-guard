// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContextGuard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "context-guard", targets: ["context-guard"]),
        // Not "ContextGuard": APFS is case-insensitive, and the two binaries share .build/release.
        .executable(name: "ContextGuardApp", targets: ["ContextGuardApp"]),
    ],
    targets: [
        .target(name: "ContextGuardCore"),
        .executableTarget(name: "context-guard", dependencies: ["ContextGuardCore"]),
        .executableTarget(name: "ContextGuardApp", dependencies: ["ContextGuardCore"]),
        // Fixtures both test targets use.
        .target(name: "ContextGuardTestSupport", path: "Tests/ContextGuardTestSupport"),
        .testTarget(name: "ContextGuardCoreTests", dependencies: ["ContextGuardCore", "ContextGuardTestSupport"]),
    ]
)
