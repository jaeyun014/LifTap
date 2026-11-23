// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LifTap",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LifTap", targets: ["LifTap"])],
    targets: [
        .executableTarget(name: "LifTap"),
        .testTarget(name: "LifTapTests", dependencies: ["LifTap"])
    ]
)
