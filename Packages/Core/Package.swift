// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "Core", targets: ["Core"])],
    dependencies: [.package(path: "../Ports")],
    targets: [
        .target(name: "Core", dependencies: ["Ports"]),
        .testTarget(name: "CoreTests", dependencies: ["Core", .product(name: "PortsTesting", package: "Ports")]),
    ]
)
