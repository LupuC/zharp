// swift-tools-version: 5.9
import PackageDescription

// Zharp for macOS. ZharpCore is the pure-Swift terminal engine (the port of
// Zharp.Core: VT parser, emulator, screen buffers, palettes, PTY host);
// ZharpApp is the AppKit shell that renders it. ZharpCoreSmokeTests mirrors
// the Windows build's console test runner - exit code = failures - so it runs
// with the Command Line Tools alone (XCTest needs a full Xcode install).
let package = Package(
    name: "Zharp",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ZharpCore", targets: ["ZharpCore"]),
        .executable(name: "Zharp", targets: ["ZharpApp"]),
        .executable(name: "ZharpCoreSmokeTests", targets: ["ZharpCoreSmokeTests"]),
    ],
    targets: [
        .target(
            name: "ZharpCore",
            path: "Sources/ZharpCore"
        ),
        .executableTarget(
            name: "ZharpApp",
            dependencies: ["ZharpCore"],
            path: "Sources/ZharpApp",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "ZharpCoreSmokeTests",
            dependencies: ["ZharpCore"],
            path: "Tests/ZharpCoreSmokeTests"
        ),
    ]
)
