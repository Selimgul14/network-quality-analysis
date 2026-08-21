// swift-tools-version: 5.9
import PackageDescription

// All measurement logic lives here rather than in the app target so it can
// be built and tested from the command line on macOS. The iOS app is a thin
// SwiftUI shell over this package.
let package = Package(
    name: "WiFiProbeKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WiFiProbeKit", targets: ["WiFiProbeKit"]),
    ],
    targets: [
        // No third-party dependencies (REQUIREMENTS.md N10).
        .target(name: "WiFiProbeKit"),
        .testTarget(
            name: "WiFiProbeKitTests",
            dependencies: ["WiFiProbeKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
