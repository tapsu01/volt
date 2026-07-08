// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TransmitLite",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TransmitLite", targets: ["TransmitLite"])
    ],
    targets: [
        .executableTarget(
            name: "TransmitLite",
            path: "Sources/TransmitLite"
        )
    ]
)
