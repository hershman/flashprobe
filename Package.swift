// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "flashprobe",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "flashprobe", targets: ["flashprobe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Hardware-facing and pure logic. Phase 5 only uses IOKit/DiskArbitration
        // for *looking up* the drive and /dev/rdiskN for read-only access.
        .target(
            name: "FlashProbeCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .executableTarget(
            name: "flashprobe",
            dependencies: [
                "FlashProbeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "FlashProbeCoreTests",
            dependencies: ["FlashProbeCore"]
        ),
    ]
)
