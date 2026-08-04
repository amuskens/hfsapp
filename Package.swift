// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HFSApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "HFSApp",
            targets: ["HFSApp"]
        )
    ],
    targets: [
        .executableTarget(
            name: "HFSApp",
            path: "Sources/HFSApp"
        ),
        .testTarget(
            name: "HFSAppTests",
            dependencies: ["HFSApp"]
        )
    ],
    swiftLanguageModes: [.v6]
)
