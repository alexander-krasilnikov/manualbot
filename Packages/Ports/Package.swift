// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Ports",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Ports", targets: ["Ports"]),
        .library(name: "PortsTesting", targets: ["PortsTesting"]),
    ],
    targets: [
        .target(name: "Ports"),
        .target(name: "PortsTesting", dependencies: ["Ports"]),
        .testTarget(name: "PortsTests", dependencies: ["Ports", "PortsTesting"]),
    ]
)
