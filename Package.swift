// swift-tools-version:5.9
import PackageDescription

// This manifest exists ONLY to run the unit gate (`swift test`). The canonical
// app is still built by ./build.sh (plain swiftc over Sources/*.swift); nothing
// here feeds that build. `ClaudeUsageCore` compiles every source EXCEPT
// main.swift (the sole top-level-code file, which cannot live in a library
// target), so the tests can `@testable import` the app's real types.
let package = Package(
    name: "ClaudeUsage",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ClaudeUsageCore",
            path: "Sources",
            exclude: ["main.swift"]
        ),
        .testTarget(
            name: "ClaudeUsageTests",
            dependencies: ["ClaudeUsageCore"],
            path: "Tests"
        ),
    ]
)
