// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Volt",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Volt", targets: ["Volt"])
    ],
    targets: [
        .executableTarget(
            name: "Volt",
            path: "Sources/Volt"
        )
    ]
)
