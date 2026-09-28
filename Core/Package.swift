// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShiftCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "ShiftCore", targets: ["ShiftCore"])],
    targets: [
        .target(name: "ShiftCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ShiftCoreTests", dependencies: ["ShiftCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
