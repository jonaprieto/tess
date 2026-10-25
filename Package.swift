// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "tess",
    platforms: [.macOS(.v27)],
    targets: [
        // Pure model and rules: no AppKit, everything here is unit tested.
        .target(name: "Layout"),
        // AppKit/AX glue. Swift 5 mode: AX and CF types are not Sendable.
        .executableTarget(name: "tess", dependencies: ["Layout"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LayoutTests", dependencies: ["Layout"]),
    ]
)
