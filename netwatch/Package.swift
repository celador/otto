// swift-tools-version:6.0
// otto-netwatch: Otto's hotspot failover helper. Runs outside the App Store app (which is sandboxed and
// can't change Wi-Fi networks) as a per-user LaunchAgent installed by scripts/install_netwatch.sh.
// See netwatch/README.md.
import PackageDescription

let package = Package(
    name: "OttoNetwatch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "otto-netwatch", targets: ["otto-netwatch"]),
    ],
    targets: [
        // Pure logic: the failover state machine, config/status files. No CoreWLAN, no clocks.
        .target(name: "NetwatchCore"),
        // The helper: CoreWLAN, CoreLocation, Keychain, connectivity probes, the run loop and the CLI.
        .executableTarget(
            name: "otto-netwatch",
            dependencies: ["NetwatchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .testTarget(name: "NetwatchCoreTests", dependencies: ["NetwatchCore"]),
    ]
)
