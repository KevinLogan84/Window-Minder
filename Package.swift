// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WindowMinder",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WindowMinderCore", targets: ["WindowMinderCore"]),
    ],
    targets: [
        .target(
            name: "WindowMinderCore",
            path: "Sources/WindowMinderCore"
        ),
        .testTarget(
            name: "WindowMinderCoreTests",
            dependencies: ["WindowMinderCore"],
            path: "Tests/WindowMinderCoreTests"
        ),
    ]
)
