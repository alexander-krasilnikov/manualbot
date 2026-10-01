// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Adapters",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Adapters", targets: ["Adapters"])],
    dependencies: [
        .package(path: "../Ports"),
        .package(path: "../Core"),
        .package(path: "../LiteRTLMKit"),
        .package(url: "https://github.com/couchbase/couchbase-lite-swift-ee.git", exact: "4.1.2"),
        .package(url: "https://github.com/couchbase/couchbase-lite-vector-search-spm.git", exact: "2.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.9"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.4"),
    ],
    targets: [
        .target(
            name: "Adapters",
            dependencies: [
                "Ports", "Core",
                .product(name: "CouchbaseLiteSwift", package: "couchbase-lite-swift-ee"),
                .product(name: "CouchbaseLiteVectorSearch", package: "couchbase-lite-vector-search-spm"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "LiteRTLM", package: "LiteRTLMKit"),
            ]),
        .testTarget(
            name: "AdaptersTests", dependencies: ["Adapters", .product(name: "PortsTesting", package: "Ports")],
            resources: [.process("Resources")]),
    ]
)
