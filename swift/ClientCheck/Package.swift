// swift-tools-version: 6.0
import Foundation
import PackageDescription

// SwiftPM names a path dependency after its directory, which is wherever the repository was
// cloned to.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appendingPathComponent("../..").standardizedFileURL

let package = Package(
  name: "ClientCheck",
  platforms: [.macOS(.v12)],
  dependencies: [.package(path: root.path)],
  targets: [
    .target(
      name: "ClientCheck",
      dependencies: [
        .product(name: "Hron", package: root.lastPathComponent.lowercased())
      ])
  ]
)
