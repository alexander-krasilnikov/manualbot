// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [.library(name: "Core", targets: ["Core"])],
    dependencies: [.package(path: "../Ports")],
    targets: [
        .target(name: "Core", dependencies: ["Ports"]),
        .testTarget(name: "CoreTests", dependencies: ["Core", .product(name: "PortsTesting", package: "Ports")]),
    ]
)
