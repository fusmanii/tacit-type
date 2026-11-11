// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TacitKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "TacitKit", targets: ["TacitKit"]),
    ],
    targets: [
        .target(name: "TacitKit"),
        .testTarget(name: "TacitKitTests", dependencies: ["TacitKit"]),
    ]
)
