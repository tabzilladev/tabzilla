// swift-tools-version: 5.9
// NOTE: This Package.swift is used for running tests only.
// The app is built with Xcode (required for mixed Swift/Obj-C).
// See DEVELOPMENT.md for build system details.
import PackageDescription

let package = Package(
    name: "Tabzilla",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Library for testing (executable is built via Xcode, not SPM)
        .library(name: "Tabzilla", targets: ["Tabzilla"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0")
    ],
    targets: [
        .target(
            name: "Tabzilla",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources",
            exclude: [
                "Resources/Info.plist",
                "Resources/Tabzilla.entitlements",
                // Exclude Objective-C and dependent files (SPM doesn't support mixed Swift/ObjC)
                // Full app builds use Xcode which includes these files
                "Chrome.h",
                "ChromeController.h",
                "ChromeController.m",
                "Tabzilla-Bridging-Header.h",
                "Executor.swift",
                // These depend on Executor, so also excluded
                "CLI.swift",
                "TabzillaApp.swift"
            ],
            resources: [
                .process("Resources/DefaultConfig.yaml")
            ]
        ),
        .testTarget(
            name: "TabzillaTests",
            dependencies: ["Tabzilla"],
            path: "Tests"
        )
    ]
)
