// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "hron",
  platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15), .watchOS(.v9), .visionOS(.v1)],
  products: [
    .library(name: "Hron", targets: ["Hron"])
  ],
  targets: [
    .target(name: "Hron", path: "swift/Sources/Hron"),
    .testTarget(name: "HronTests", dependencies: ["Hron"], path: "swift/Tests/HronTests"),
  ]
)
