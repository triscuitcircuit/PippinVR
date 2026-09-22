// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pippinvr-server",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "pippinvr-server",
            path: "Sources/pippinvr-server"
        )
    ]
)
