// swift-tools-version:5.9
import PackageDescription
import Foundation

// GeoSentinelMacCore: the app's model and map drawing (everything except the window shell), so they can be
// tested. GeoSentinelMac is the app. MacChecks is a self-contained test runner (no Xcode/XCTest needed), only
// declared when GEOSENTINEL_TOOLS is set:   GEOSENTINEL_TOOLS=1 swift run MacChecks
let tools = ProcessInfo.processInfo.environment["GEOSENTINEL_TOOLS"] != nil
let kit: Target.Dependency = .product(name: "GeoSentinelKit", package: "geo-sentinel-ios")

var targets: [Target] = [
    .target(name: "GeoSentinelMacCore", dependencies: [kit]),
    .executableTarget(name: "GeoSentinelMac", dependencies: ["GeoSentinelMacCore", kit]),
]
if tools { targets.append(.executableTarget(name: "MacChecks", dependencies: ["GeoSentinelMacCore", kit])) }

let package = Package(
    name: "GeoSentinelMac",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "..")],
    targets: targets
)
