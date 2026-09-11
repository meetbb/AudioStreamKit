// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioStreamKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "AudioStreamKit",
            targets: ["AudioStreamKit"]
        )
    ],
    targets: [
        .target(
            name: "AudioStreamKit"
        ),
        .testTarget(
            name: "AudioStreamKitTests",
            dependencies: ["AudioStreamKit"]
        )
    ]
)
