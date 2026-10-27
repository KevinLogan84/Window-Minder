// swift-tools-version: 5.9

import PackageDescription

// Linux has no AppKit, SwiftUI, or the other Apple modules the app imports.
// `swift test` still typechecks `WindowMinder/*.swift` there, against stubs whose
// method labels match the macOS SDK. On macOS the core library stays AppKit-free
// so it does not shadow the real SDK. Xcode builds the app from the project, not
// from these stubs.

#if os(Linux)
let platformTargets: [Target] = [
    .target(name: "CoreFoundation", path: "Stubs/CoreFoundation"),
    .target(name: "CoreGraphics", dependencies: ["CoreFoundation"], path: "Stubs/CoreGraphics"),
    .target(
        name: "ApplicationServices",
        dependencies: ["CoreFoundation", "CoreGraphics"],
        path: "Stubs/ApplicationServices"
    ),
    .target(name: "Carbon", path: "Stubs/Carbon"),
    .target(name: "os", path: "Stubs/os"),
    .target(name: "ServiceManagement", path: "Stubs/ServiceManagement"),
    .target(name: "AppKit", path: "Stubs/AppKit"),
    .target(name: "SwiftUI", dependencies: ["AppKit"], path: "Stubs/SwiftUI"),
    .target(
        name: "WindowMinderCore",
        dependencies: [
            "AppKit",
            "SwiftUI",
            "Carbon",
            "CoreGraphics",
            "CoreFoundation",
            "ApplicationServices",
            "ServiceManagement",
            "os",
        ],
        path: ".",
        exclude: [
            "docs",
            "scripts",
            "Stubs",
            "Tests",
            "WindowMinder.xcodeproj",
            ".github",
            ".gitignore",
            "Package.swift",
            "README.md",
            "WindowMinder/Info.plist",
            "WindowMinder/AppIcon.svg",
            "WindowMinder/Assets.xcassets",
            "WindowMinder/AppIcon.icon",
        ],
        sources: [
            "Sources/WindowMinderCore",
            "WindowMinder",
        ]
    ),
]
#else
let platformTargets: [Target] = [
    .target(
        name: "WindowMinderCore",
        path: "Sources/WindowMinderCore"
    ),
]
#endif

let package = Package(
    name: "WindowMinder",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WindowMinderCore", targets: ["WindowMinderCore"]),
    ],
    targets: platformTargets + [
        .testTarget(
            name: "WindowMinderCoreTests",
            dependencies: ["WindowMinderCore"],
            path: "Tests/WindowMinderCoreTests"
        ),
    ]
)
