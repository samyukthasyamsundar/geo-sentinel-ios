// swift-tools-version:5.9
import PackageDescription
import Foundation

// GeoSentinelKit holds all the detection logic and has no iOS dependencies, so it builds and runs on a
// Mac with only the command-line tools.
//
// KitChecks and KitDemo are command-line tools for testing on a Mac (the standard test frameworks need a
// full Xcode install). They are only declared when GEOSENTINEL_TOOLS is set, so that when Xcode resolves
// this package for the iPhone app it sees the library alone. Run them with:
//     GEOSENTINEL_TOOLS=1 swift run KitChecks
let tools = ProcessInfo.processInfo.environment["GEOSENTINEL_TOOLS"] != nil

var targets: [Target] = [.target(name: "GeoSentinelKit")]
if tools {
    targets.append(.executableTarget(name: "KitChecks", dependencies: ["GeoSentinelKit"]))
    targets.append(.executableTarget(name: "KitDemo", dependencies: ["GeoSentinelKit"]))
}

let package = Package(
    name: "GeoSentinelKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "GeoSentinelKit", targets: ["GeoSentinelKit"])],
    targets: targets
)
