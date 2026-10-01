// swift-tools-version: 5.9
import PackageDescription

// A vendored copy of the Swift wrapper from google-ai-edge/LiteRT-LM (Apache-2.0), tag v0.17.1.
// Upstream's repository keeps files in Git LFS (one object is missing at this tag), which breaks a plain
// SwiftPM checkout. The prebuilt binaries below come from GitHub release assets, so vendoring the small
// wrapper avoids needing git-lfs or special environment variables anywhere.
let package = Package(
  name: "LiteRTLMKit",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [.library(name: "LiteRTLM", targets: ["LiteRTLM"])],
  targets: [
    .binaryTarget(
      name: "CLiteRTLM",
      url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.17.1/CLiteRTLM.xcframework.zip",
      checksum: "c94fc12aa0403cb47208e419cc3bfe258214ea17035f7a63c16de536869f2186"
    ),
    .binaryTarget(
      name: "CLiteRTLM_mac",
      url: "https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.17.1/CLiteRTLM_mac.xcframework.zip",
      checksum: "83efd536485c9d58fcd7fb7d4556ddb16ca46bb775b0449d08d9825c6836c1a4"
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
