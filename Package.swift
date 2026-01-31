// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tabzilla",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Tabzilla", targets: ["Tabzilla"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0")
    ],
    targets: [
        .executableTarget(
            name: "Tabzilla",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams")
            ],
            path: "Sources",
            exclude: [
                "Resources/Info.plist",
                "Resources/Tabzilla.entitlements"
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
