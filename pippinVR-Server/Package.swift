// swift-tools-version: 6.0
import Foundation
import PackageDescription

let newtArchive = Context.packageDirectory + "/.build/newt-package/lib/libnewt_core.a"
let directEnabled = FileManager.default.fileExists(atPath: newtArchive)
let xrVendorLibDir = Context.packageDirectory + "/.build/monado-vendor/lib"

func detectVulkanSDK() -> String? {
    if let override = ProcessInfo.processInfo.environment["VULKAN_SDK"] { return override }
    let fm = FileManager.default
    let base = fm.homeDirectoryForCurrentUser.path + "/VulkanSDK"
    guard let versions = try? fm.contentsOfDirectory(atPath: base) else { return nil }
    for version in versions.sorted(by: >) {
        let candidate = base + "/" + version + "/macOS"
        if fm.fileExists(atPath: candidate + "/include/vulkan/vulkan.h") { return candidate }
    }
    return nil
}

func detectOpenXRIncludeDir() -> String? {
    if let override = ProcessInfo.processInfo.environment["OPENXR_INCLUDE_DIR"] { return override }
    let candidate = Context.packageDirectory + "/third_party/openxr-sdk/include"
    return FileManager.default.fileExists(atPath: candidate + "/openxr/openxr.h") ? candidate : nil
}

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
    guard let openxrIncludeDir = detectOpenXRIncludeDir() else {
        fatalError("""
            Direct build detected (.build/newt-package exists) but no OpenXR \
            headers were found at third_party/openxr-sdk/include (run \
            build-monado.sh to fetch them) and OPENXR_INCLUDE_DIR isn't set \
            either. Point it at the OpenXR SDK's include/ directory, then \
            re-run `swift build`.
            """)
    }
    guard let vulkanSDK = detectVulkanSDK() else {
        fatalError("""
            Direct build detected (.build/newt-package exists) but no Vulkan \
            SDK was found under ~/VulkanSDK and VULKAN_SDK isn't set either. \
            Install the Vulkan SDK or point VULKAN_SDK at it, then re-run \
            `swift build`.
            """)
    }
    let newtPackageInclude = Context.packageDirectory + "/.build/newt-package/include"
    targets.append(.target(
        name: "Newt",
        path: "NewtBridge",
        sources: ["Bridge.c"],
        publicHeadersPath: "include"
    ))
    targets.append(.target(
        name: "NewtDashboard",
        dependencies: ["Newt"],
        path: "Sources/NewtDashboard",
        publicHeadersPath: ".",
        cSettings: [
            .unsafeFlags([
                "-fobjc-arc",
                "-DXR_USE_GRAPHICS_API_VULKAN",
                "-I" + newtPackageInclude,
                "-I" + Context.packageDirectory + "/.build/newt-package",
                "-I" + openxrIncludeDir,
                "-I" + vulkanSDK + "/include"
            ])
        ],
        cxxSettings: [
            .unsafeFlags([
                "-DXR_USE_GRAPHICS_API_VULKAN",
                "-I" + newtPackageInclude,
                "-I" + Context.packageDirectory + "/.build/newt-package",
                "-I" + openxrIncludeDir,
                "-I" + vulkanSDK + "/include"
            ])
        ],
        linkerSettings: [
            .unsafeFlags([
                "-L" + Context.packageDirectory + "/.build/newt-package/lib",
                "-lnewt_core",
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
    serverDependencies.append("NewtDashboard")
    serverSwiftSettings.append(.define("PIPPINVR_DIRECT"))
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
    targets: targets,
    cxxLanguageStandard: .cxx17
)
