// swift-tools-version: 6.0
import Foundation
import PackageDescription

// SwiftPM names a path dependency after its directory, which is wherever the repository was
// cloned to.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("../../../..").standardizedFileURL

let package = Package(
  name: "hron-differential",
  platforms: [.macOS(.v13)],
  dependencies: [.package(path: root.path)],
  targets: [
    .executableTarget(
      name: "hron-differential",
      dependencies: [
        .product(name: "Hron", package: root.lastPathComponent.lowercased())
      ])
  ]
)
