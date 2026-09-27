// swift-tools-version: 6.0
import PackageDescription

// Pure logic ported from web/src. No UIKit, no MapKit, no MapLibre: the app
// target owns the map, this package owns the math. Builds for macOS as well as
// iOS so `swift test` runs in CI without a simulator.
let package = Package(
    name: "RouteKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RouteKit", targets: ["RouteKit"])
    ],
    targets: [
        .target(name: "RouteKit"),
        .testTarget(name: "RouteKitTests", dependencies: ["RouteKit"]),
    ]
)