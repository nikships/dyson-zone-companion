// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DysonZone",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DysonZone",
            path: "Sources/DysonZone",
            linkerSettings: [.linkedFramework("IOBluetooth"), .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")]
        ),
        .testTarget(
            name: "DysonZoneTests",
            dependencies: ["DysonZone"],
            path: "Tests/DysonZoneTests"
        )
    ]
)
