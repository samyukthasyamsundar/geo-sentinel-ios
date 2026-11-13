// swift-tools-version:5.9
import PackageDescription

// GeoSentinelKit holds all the detection logic and has no iOS dependencies, so it builds and runs on a
// Mac with only the command-line tools. KitChecks is a self-contained test runner (the standard test
// frameworks need a full Xcode install); it exits non-zero if any check fails.
let package = Package(
    name: "GeoSentinelKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "GeoSentinelKit", targets: ["GeoSentinelKit"])],
    targets: [
        .target(name: "GeoSentinelKit"),
        .executableTarget(name: "KitChecks", dependencies: ["GeoSentinelKit"]),
        .executableTarget(name: "KitDemo", dependencies: ["GeoSentinelKit"]),
    ]
)
