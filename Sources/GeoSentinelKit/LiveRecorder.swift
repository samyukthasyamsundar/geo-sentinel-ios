import Foundation

/// Accumulates fixes as they arrive from a location source and keeps the trace bounded.
/// Pure logic with no iOS dependency, so it is tested here; the app feeds it from CoreLocation.
public final class LiveRecorder {
    public private(set) var fixes: [Fix] = []
    /// Fixes with a negative or absurd accuracy are not real measurements (CoreLocation uses a negative
    /// horizontalAccuracy to mean "this coordinate is invalid"), so they are dropped, not stored.
    public private(set) var rejected = 0
    public let capacity: Int

    public init(capacity: Int = TraceLimits.maxPoints) { self.capacity = max(1, capacity) }

    /// Adds a fix. Returns false if it was rejected as not a valid measurement.
    @discardableResult
    public func add(lat: Double, lon: Double, accuracyM: Double?, time: Date) -> Bool {
        let p = GeoPoint(lat: lat, lon: lon)
        guard p.isValid else { rejected += 1; return false }
        if let a = accuracyM, !(a >= 0 && a.isFinite) { rejected += 1; return false }
        fixes.append(Fix(point: p, time: time, accuracyM: accuracyM, line: 0))
        if fixes.count > capacity { fixes.removeFirst(fixes.count - capacity) }   // keep the newest
        return true
    }

    public func reset() { fixes.removeAll(); rejected = 0 }
    public var trace: Trace { Trace(fixes: fixes) }

    /// Verdict for what has been recorded so far. Needs a handful of fixes to say anything useful.
    public func assess(config: Config = Config()) -> (verdict: Verdict, findings: [Finding])? {
        guard fixes.count >= 2 else { return nil }
        let f = Detector.analyze(trace, config: config)
        return (Detector.judge(f), f)
    }
}
