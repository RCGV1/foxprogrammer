// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "PicoFoxCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PicoFoxCore", targets: ["PicoFoxCore"])],
    targets: [
        .target(name: "PicoFoxCore", resources: [.process("Resources")]),
        .testTarget(name: "PicoFoxCoreTests", dependencies: ["PicoFoxCore"])
    ]
)
