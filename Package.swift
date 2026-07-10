// swift-tools-version: 6.0

import PackageDescription
import Foundation

let libssh2Prefix = ProcessInfo.processInfo.environment["VOLT_LIBSSH2_PREFIX"]
    ?? "/usr/local/opt/libssh2"

let package = Package(
    name: "Volt",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Volt", targets: ["Volt"])
    ],
    targets: [
        .target(
            name: "CVoltSSH",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I\(libssh2Prefix)/include"])
            ],
            linkerSettings: [
                .linkedLibrary("ssh2"),
                .unsafeFlags(["-L\(libssh2Prefix)/lib"])
            ]
        ),
        .executableTarget(
            name: "Volt",
            dependencies: ["CVoltSSH"],
            path: "Sources/Volt"
        )
    ]
)
