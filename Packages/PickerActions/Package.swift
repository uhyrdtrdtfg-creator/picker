// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PickerActions",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PickerActions",
            targets: ["PickerActions"]
        )
    ],
    targets: [
        .target(
            name: "PickerActions"
        ),
        .testTarget(
            name: "PickerActionsTests",
            dependencies: ["PickerActions"]
        )
    ]
)
