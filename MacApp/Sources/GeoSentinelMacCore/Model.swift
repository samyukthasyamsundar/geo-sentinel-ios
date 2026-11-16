import Foundation
import GeoSentinelKit

/// What the user is analysing and what we concluded. No UI code here, so it can be tested without a window.
public struct Analysis: Equatable {
    public var fileName: String
    public var trace: Trace
    public var findings: [Finding]
    public var verdict: Verdict
    /// Computed ONCE when the file is analysed, then only read. The views redraw 30 times a second during a replay,
    /// so computing statistics (a pass over up to half a million fixes) inside a view would make big files stutter.
    public let stats: TripStats
    /// First and last timestamps, for the replay clock.
    public let duration: TimeInterval

    public init(fileName: String, trace: Trace, findings: [Finding], verdict: Verdict) {
        self.fileName = fileName; self.trace = trace; self.findings = findings; self.verdict = verdict
        self.stats = Stats.compute(trace)
        self.duration = self.stats.duration
    }

    public static func == (a: Analysis, b: Analysis) -> Bool {
        a.fileName == b.fileName && a.verdict == b.verdict && a.findings == b.findings && a.trace.fixes == b.trace.fixes
    }
}

/// Speed limit presets. The biggest source of false "faked" verdicts is analysing a flight, or a train,
/// with the limit meant for a car, so the limit is a visible, first-class setting.
public enum SpeedPreset: String, CaseIterable, Identifiable {
    case onFoot = "On foot or bike"
    case car = "Car"
    case train = "Train"
    case aircraft = "Aircraft"

    public var id: String { rawValue }
    /// Fastest speed treated as plausible, in km/h.
    public var kmh: Double {
        switch self { case .onFoot: 60; case .car: 306; case .train: 450; case .aircraft: 1200 }
    }
}

public enum Loader {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupportedType(String)
        case unreadable(String)
        case parse(String)
        public var description: String {
            switch self {
            case .unsupportedType(let e): return e.isEmpty ? "This file has no extension. Use a .csv or .gpx file." : "Unsupported file type \".\(e)\". Use a .csv or .gpx file."
            case .unreadable(let m): return "Could not read the file: \(m)"
            case .parse(let m): return m
            }
        }
    }

    /// Reads and analyses a file. The file is untrusted input; everything it can do is bounded by the parsers.
    public static func analyse(url: URL, speed: SpeedPreset) -> Result<Analysis, Failure> {
        let ext = url.pathExtension.lowercased()
        guard ext == "csv" || ext == "gpx" else { return .failure(.unsupportedType(ext)) }
        let data: Data
        do {
            // Refuse oversized files before reading them into memory.
            let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > TraceLimits.maxBytes { return .failure(.parse("The file is larger than \(TraceLimits.maxBytes / 1_048_576) MB.")) }
            data = try Data(contentsOf: url)
        } catch { return .failure(.unreadable(error.localizedDescription)) }
        return analyse(data: data, fileName: url.lastPathComponent, ext: ext, speed: speed)
    }

    public static func analyse(data: Data, fileName: String, ext: String, speed: SpeedPreset) -> Result<Analysis, Failure> {
        let trace: Trace
        do { trace = ext == "gpx" ? try GPXParser.parse(data) : try CSVParser.parse(data) }
        catch let e as ParseError { return .failure(.parse(e.description)) }
        catch { return .failure(.parse(error.localizedDescription)) }

        // A trace with out-of-range coordinates cannot be drawn or measured, so say so.
        if let bad = trace.fixes.first(where: { !$0.point.isValid }) {
            return .failure(.parse(bad.line > 0 ? "line \(bad.line): coordinates out of range" : "coordinates out of range"))
        }
        var cfg = Config()
        cfg.maxSpeedMS = speed.kmh / 3.6
        let findings = Detector.analyze(trace, config: cfg)
        return .success(Analysis(fileName: fileName, trace: trace, findings: findings, verdict: Detector.judge(findings)))
    }
}

/// What the list shows: findings of the same kind and confidence with the same wording are one row with a
/// count, because eight identical "implied speed 765 km/h" lines bury everything else. Order follows the first
/// occurrence, and the fix indices of every merged finding are kept so the map can highlight them all.
public struct FindingGroup: Equatable, Identifiable {
    public let check: String
    public let confidence: Confidence
    public let reason: String
    public let fixIndices: [Int]
    public var count: Int { fixIndices.isEmpty ? 1 : fixIndices.count }
    public var id: String { "\(check)|\(confidence)|\(reason)" }
}

/// Groups findings whose text (ignoring the digits that vary per row, like a timestamp) is otherwise identical.
public func grouped(_ findings: [Finding]) -> [FindingGroup] {
    var order: [String] = []
    var buckets: [String: (Finding, [Int], Int)] = [:]
    for f in findings {
        let key = "\(f.check)|\(f.confidence)|\(f.reason)"
        if buckets[key] == nil { order.append(key); buckets[key] = (f, [], 0) }
        buckets[key]!.2 += 1
        if f.fixIndex >= 0 { buckets[key]!.1.append(f.fixIndex) }
    }
    return order.map { k in
        let (f, idx, n) = buckets[k]!
        return FindingGroup(check: f.check, confidence: f.confidence, reason: n > 1 ? "\(f.reason)  (\(n) times)" : f.reason, fixIndices: idx)
    }
}

/// One-sentence plain-language summary of a result.
public func summary(for a: Analysis) -> String {
    let n = a.trace.fixes.count
    switch a.verdict {
    case .clean:
        return a.findings.isEmpty
            ? "Nothing impossible was found in \(n) positions."
            : "Nothing impossible was found in \(n) positions, but there \(a.findings.count == 1 ? "is one note" : "are \(a.findings.count) notes") below."
    case .suspicious:
        return "Some things in these \(n) positions look wrong, but none is conclusive."
    case .likelySpoofed:
        return "These \(n) positions contain movement that no real device could produce."
    }
}
