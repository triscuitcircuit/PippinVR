// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pippinvr-server",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .target(
            name: "LoggingCore",
            path: "Sources/LoggingCore",
            publicHeadersPath: "."
        ),
        .target(
            name: "IOSDeviceCore",
            dependencies: ["LoggingCore"],
            path: "Sources/IOSDeviceCore",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "pippinvr-server",
            dependencies: ["LoggingCore", "IOSDeviceCore"],
            path: "Sources/pippinvr-server"
        )
    ]
)
