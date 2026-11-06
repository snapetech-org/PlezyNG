// swift-tools-version: 5.8
import PackageDescription

let package = Package(
  name: "PlezyNGDVRuntimeAPI",
  platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15)],
  products: [.library(name: "PlezyNGDVRuntimeAPI", type: .dynamic, targets: ["PlezyNGDVRuntimeAPI"])],
  targets: [
    .target(name: "PlezyNGDVRuntimeAPI"),
    .testTarget(name: "PlezyNGDVRuntimeAPITests", dependencies: ["PlezyNGDVRuntimeAPI"]),
  ]
)
