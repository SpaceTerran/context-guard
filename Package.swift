// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .executable(name: "context-guard", targets: ["context-guard"]),
]
var targets: [Target] = [
    .target(name: "ContextGuardCore"),
    // `context-guard codex`: talks to the Codex app server. Only the CLI uses it.
    .target(name: "ContextGuardCodexLink", dependencies: ["ContextGuardCore"]),
    .executableTarget(name: "context-guard", dependencies: ["ContextGuardCore", "ContextGuardCodexLink"]),
    // Fixtures both test targets use.
    .target(name: "ContextGuardTestSupport", path: "Tests/ContextGuardTestSupport"),
    .testTarget(name: "ContextGuardCoreTests", dependencies: ["ContextGuardCore", "ContextGuardTestSupport"]),
    .testTarget(name: "ContextGuardCodexLinkTests",
                dependencies: ["ContextGuardCodexLink", "ContextGuardCore", "ContextGuardTestSupport"]),
]

// The menu bar app (SwiftUI and AppKit) is the Mac's only. Windows has its own app.
#if os(macOS)
// Not "ContextGuard": APFS is case-insensitive, and the two binaries share .build/release.
products.append(.executable(name: "ContextGuardApp", targets: ["ContextGuardApp"]))
targets.append(.executableTarget(name: "ContextGuardApp", dependencies: ["ContextGuardCore"]))
#endif

// The Codex link the Windows background task runs: `context-guard codex`'s code, linked as a GUI
// program so it opens no console window. The Mac's LaunchAgent runs `context-guard codex` itself.
#if os(Windows)
products.append(.executable(name: "context-guard-link", targets: ["context-guard-link"]))
targets.append(.executableTarget(
    name: "context-guard-link",
    dependencies: ["ContextGuardCore", "ContextGuardCodexLink"],
    linkerSettings: [.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"])]))
#endif

let package = Package(
    name: "ContextGuard",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
