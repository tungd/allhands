// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AllHandsKit",
    platforms: [
        .iOS("26.0"),
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "AllHandsKit",
            targets: ["AllHandsKit"]
        )
    ],
    targets: [
        .target(
            name: "AllHandsKit"
        ),
        .testTarget(
            name: "AllHandsKitTests",
            dependencies: ["AllHandsKit"]
        )
    ]
)
