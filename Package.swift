// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FloppyFox",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "FloppyFox",
            targets: ["FloppyFox"]
        )
    ],
    targets: [
        .executableTarget(
            name: "FloppyFox",
            path: "Sources/FloppyFox",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "FloppyFoxTests",
            dependencies: ["FloppyFox"]
        )
    ],
    swiftLanguageModes: [.v6]
)
