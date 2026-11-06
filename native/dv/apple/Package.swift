// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "PlezyNGDVRuntime",
  platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18)],
  products: [.library(name: "PlezyNGDVRuntime", type: .dynamic, targets: ["PlezyNGDVRuntime"])],
  dependencies: [
    .package(path: "../../../shared/apple/DVRuntimeAPI"),
    // This trait is always built into the shipped runtime. Settings controls
    // LoadOptions.preferDualLayerDolbyVision; users never need a custom build.
    .package(
      url: "https://github.com/superuser404notfound/AetherEngine.git",
      revision: "e6f785a96ab68336966f8d01305d289f87b59752",
      traits: ["DualLayerDolbyVision"]
    ),
  ],
  targets: [
    .target(
      name: "PlezyNGDVRuntime",
      dependencies: [
        .product(name: "PlezyNGDVRuntimeAPI", package: "DVRuntimeAPI"),
        .product(name: "AetherEngine", package: "AetherEngine"),
      ])
  ],
  swiftLanguageModes: [.v5]
)
