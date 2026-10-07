// swift-tools-version: 5.9
import PackageDescription

// A vendored copy of the Swift wrapper from google-ai-edge/LiteRT-LM (Apache-2.0), tag v0.18.0.
// Upstream's repository keeps files in Git LFS (one object was missing at v0.17.1), which breaks a plain
// SwiftPM checkout. The prebuilt binaries below come from GitHub release assets, so vendoring the small
// wrapper avoids needing git-lfs or special environment variables anywhere.
let package = Package(
  name: "LiteRTLMKit",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [.library(name: "LiteRTLM", targets: ["LiteRTLM"])],
  targets: [
    .binaryTarget(
      name: "CLiteRTLM",
      url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.18.0/CLiteRTLM.xcframework.zip",
      checksum: "d765b99592d4ec3d0c9e2bd69469454af06c834861340672da1891c0c121c347"
    ),
    .binaryTarget(
      name: "CLiteRTLM_mac",
      url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.18.0/CLiteRTLM_mac.xcframework.zip",
      checksum: "5f6ee68d95eeccb084c6e66d5ee47255e3020fa0fb29696dd0301ae26d6cfb4f"
    ),
    .target(
      name: "LiteRTLM",
      dependencies: [
        .target(name: "CLiteRTLM", condition: .when(platforms: [.iOS])),
        .target(name: "CLiteRTLM_mac", condition: .when(platforms: [.macOS])),
      ]
    ),
  ]
)
