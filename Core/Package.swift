// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShiftCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "ShiftCore", targets: ["ShiftCore"]),
        .library(name: "ShiftProtocol", targets: ["ShiftProtocol"]),
    ],
    targets: [
        // Builds for macOS and iOS: no Process, no AppKit.
        .target(name: "ShiftProtocol", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "ShiftCore", dependencies: ["ShiftProtocol"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ShiftCoreTests", dependencies: ["ShiftCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
