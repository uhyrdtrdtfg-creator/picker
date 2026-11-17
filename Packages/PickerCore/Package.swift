// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PickerCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PickerCore",
            targets: ["PickerCore"]
        )
    ],
    targets: [
        .target(
            name: "PickerCore"
        ),
        .testTarget(
            name: "PickerCoreTests",
            dependencies: ["PickerCore"]
        )
    ]
)
