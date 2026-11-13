import Foundation
import GeoSentinelKit

// Prints the verdict and findings for a CSV file, as the app would show them.
guard CommandLine.arguments.count == 2, let data = FileManager.default.contents(atPath: CommandLine.arguments[1]) else {
    print("usage: KitDemo trace.csv"); exit(64)
}
do {
    let t = try CSVParser.parse(data)
    let fs = Detector.analyze(t)
    print("verdict: \(Detector.judge(fs).rawValue)  (\(t.fixes.count) fixes, \(fs.count) finding(s))")
    for f in fs { print("  [\(f.confidence)] \(f.check): \(f.reason)") }
} catch { print("error: \(error)"); exit(3) }
