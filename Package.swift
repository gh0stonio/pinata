// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Pinata",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Pinata", targets: ["Pinata"]),
    ],
    targets: [
        .executableTarget(name: "Pinata", path: "Sources/Pinata"),
    ]
)
