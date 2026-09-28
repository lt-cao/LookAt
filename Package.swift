// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LookAt",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "LookAt", targets: ["LookAt"])
    ],
    targets: [
        .executableTarget(
            name: "LookAt",
            path: "Sources/TaoView"
        ),
        .testTarget(
            name: "LookAtTests",
            dependencies: ["LookAt"]
        )
    ]
)
