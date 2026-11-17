// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OchesCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "OchesCore", targets: ["OchesCore"])],
    targets: [
        .target(name: "OchesCore"),
        .testTarget(name: "OchesCoreTests", dependencies: ["OchesCore"], resources: [.copy("Fixtures")]),
    ]
)
