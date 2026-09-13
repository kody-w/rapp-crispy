// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RAPPCrispy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RAPPCrispy", targets: ["RAPPCrispy"]),
        .library(name: "RAPPCrispyCore", targets: ["RAPPCrispyCore"])
    ],
    dependencies: [.package(path: "../../rapp-tools")],
    targets: [
        .target(
            name: "RAPPCrispyCore",
            dependencies: [.product(name: "RAPPDesktopSupport", package: "rapp-tools")]
        ),
        .executableTarget(
            name: "RAPPCrispy",
            dependencies: ["RAPPCrispyCore", .product(name: "RAPPDesktopSupport", package: "rapp-tools")]
        ),
        .testTarget(name: "RAPPCrispyCoreTests", dependencies: ["RAPPCrispyCore"])
    ]
)
