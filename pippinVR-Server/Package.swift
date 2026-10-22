// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Direct USB (Monado/Newt) is opt-in at build time: it lights up only when
// build-newt.sh has installed Newt's archives into .build/newt-package.
// Without them the package builds exactly the Quest-client server it always
// did -- the Direct* sources are excluded and PIPPINVR_DIRECT stays unset.
// The NEWT_* library files themselves live in the separate Newt repository;
// nothing of Newt is vendored here beyond its public C headers (NewtBridge/).
let newtArchive = Context.packageDirectory + "/.build/newt-package/lib/libnewt_core.a"
let directEnabled = FileManager.default.fileExists(atPath: newtArchive)
let xrVendorLibDir = Context.packageDirectory + "/.build/monado-vendor/lib"

var targets: [Target] = [
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
    )
]

var serverDependencies: [Target.Dependency] = ["LoggingCore", "IOSDeviceCore"]
var serverExclude: [String] = []
var serverSwiftSettings: [SwiftSetting] = []

if directEnabled {
    targets.append(.target(
        name: "Newt",
        path: "NewtBridge",
        sources: ["Bridge.c"],
        publicHeadersPath: "include",
        linkerSettings: [
            .unsafeFlags([
                "-L" + Context.packageDirectory + "/.build/newt-package/lib",
                "-lnewt_dashboard", "-lnewt_core",
                "-L" + xrVendorLibDir,
                "-lopenxr_loader",
                "-lvulkan.1",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks/Monado",
                "-Xlinker", "-rpath", "-Xlinker", xrVendorLibDir
            ]),
            .linkedFramework("AppKit"),
            .linkedFramework("AVFoundation"),
            .linkedFramework("CoreGraphics"),
            .linkedFramework("CoreMedia"),
            .linkedFramework("CoreMediaIO"),
            .linkedFramework("CoreVideo"),
            .linkedFramework("Foundation"),
            .linkedFramework("QuartzCore"),
            .linkedFramework("ScreenCaptureKit")
        ]
    ))
    serverDependencies.append("Newt")
    serverSwiftSettings.append(.define("PIPPINVR_DIRECT"))
} else {
    serverExclude = [
        "DirectHostRequests.swift",
        "DirectMonadoSession.swift",
        "DirectStatusItem.swift",
        "DirectSettingsView.swift",
        "NewtManagerClient.swift"
    ]
}

targets.append(.executableTarget(
    name: "pippinvr-server",
    dependencies: serverDependencies,
    path: "Sources/pippinvr-server",
    exclude: serverExclude,
    swiftSettings: serverSwiftSettings
))

let package = Package(
    name: "pippinvr-server",
    platforms: [
        .macOS(.v14)
    ],
    targets: targets
)
