// swift-tools-version: 6.0
import PackageDescription

/// Platform-independent STREAMERO logic: API clients and models for Jellyfin, Jellyseerr/Overseerr,
/// Sonarr, Radarr, Lidarr, Prowlarr and Bazarr, plus aggregation helpers. No UIKit/SwiftUI, so it
/// builds and tests on Linux CI as well.
let package = Package(
    name: "StreameroKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "StreameroKit", targets: ["StreameroKit"])],
    targets: [
        .target(name: "StreameroKit"),
        .testTarget(name: "StreameroKitTests", dependencies: ["StreameroKit"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
