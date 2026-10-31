// swift-tools-version: 6.4
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .path

let package = Package(
  name: "tess",
  platforms: [.macOS(.v27)],
  targets: [
    // Pure model and rules: no AppKit, everything here is unit
    // tested.
    .target(name: "Layout"),
    // AppKit/AX glue. Swift 5 mode: AX and CF types are not Sendable.
    .executableTarget(
      name: "tess", dependencies: ["Layout"], exclude: ["Info.plist"],
      swiftSettings: [.swiftLanguageMode(.v5)],
      // A bare binary has no bundle; its Info.plist goes in a section
      // macOS reads.
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker",
          "__info_plist",
          "-Xlinker", "\(root)/Sources/tess/Info.plist"
        ])
      ]),
    .testTarget(name: "LayoutTests", dependencies: ["Layout"]),
    .testTarget(name: "SettingsTests", dependencies: ["tess"])
  ]
)
