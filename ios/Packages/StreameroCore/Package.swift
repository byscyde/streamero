// swift-tools-version: 6.0
import PackageDescription

/// Platform-independent STREAMERO logic: API models and client, playback queue, lyrics and subtitle
/// parsing, sync bookkeeping. No UIKit/AVFoundation, so it builds and tests on Linux CI as well.
let package = Package(
    name: "StreameroCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "StreameroCore", targets: ["StreameroCore"])],
    targets: [
        .target(name: "StreameroCore"),
        .testTarget(name: "StreameroCoreTests", dependencies: ["StreameroCore"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
