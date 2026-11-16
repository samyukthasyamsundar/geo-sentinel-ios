import Foundation

public enum Confidence: Int, Comparable, Sendable, CustomStringConvertible {
    case low = 1, medium, high
    public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
    public var description: String { switch self { case .low: "low"; case .medium: "medium"; case .high: "high" } }
}

public struct Finding: Equatable, Sendable {
    public let check: String
    public let confidence: Confidence
    /// Source line of the fix concerned (0 for fixes recorded live, which have no file).
    public let line: Int
    public let time: Date
    public let reason: String
    /// Position of the fix concerned within the time-sorted trace. Unlike `line`, this identifies a fix
    /// even for live recordings (where every line is 0); it is what de-duplication keys on.
    public let fixIndex: Int

    public init(check: String, confidence: Confidence, line: Int, time: Date, fixIndex: Int = -1, reason: String) {
        self.check = check; self.confidence = confidence; self.line = line; self.time = time
        self.fixIndex = fixIndex; self.reason = reason
    }
}

public enum Verdict: String, Sendable { case clean, suspicious, likelySpoofed = "likely-spoofed" }

/// Thresholds. Defaults suit people on foot, bikes and cars; raise maxSpeedMS for trains or aircraft.
public struct Config: Sendable {
    public var maxSpeedMS = 85.0              // 306 km/h
    public var teleportM = 50_000.0
    public var maxAccelMS2 = 12.0
    public var minGapForSpeed: TimeInterval = 0.5
    public var maxGap: TimeInterval = 600
    public init() {}
}

/// Largest single-fix error treated as a plausible receiver glitch (metres).
let maxGlitchM = 200_000.0
/// How many separate lone-outlier events in one trace stop being plausibly independent glitches.
let repeatedOutliers = 5
/// The statistical checks stay silent below this many fixes.
let minStatPoints = 20

public enum Detector {
    public static func analyze(_ trace: Trace, config: Config = Config()) -> [Finding] {
        guard !trace.fixes.isEmpty else { return [] }
        let sorted = trace.sortedByTime().trace
        var out: [Finding] = []
        out += ordering(trace)                       // needs the ORIGINAL order
        out += speed(sorted, config)
        out += teleport(sorted, config)
        out += acceleration(sorted, config)
        out += accuracy(sorted)
        out += smoothness(sorted)
        out = dropExplained(out)
        return out.sorted { $0.time != $1.time ? $0.time < $1.time : $0.confidence > $1.confidence }
    }

    public static func judge(_ findings: [Finding]) -> Verdict {
        var low = 0, med = 0, motion = 0
        for f in findings {
            switch f.confidence {
            case .high: return .likelySpoofed
            case .medium: med += 1; if f.check == "teleport" || f.check == "speed" { motion += 1 }
            case .low: low += 1; if f.check == "speed" || f.check == "teleport" { motion += 1 }
            }
        }
        if motion >= repeatedOutliers { return .likelySpoofed }
        if med > 0 || low >= 3 { return .suspicious }
        return .clean
    }

    // MARK: helpers

    private static func noise(_ f: Fix) -> Double { f.accuracyM.map { min($0, 200) } ?? 0 }

    /// Fix b is close enough to fix a that the device could simply have stayed on its path.
    private static func returnsNear(_ t: [Fix], _ a: Int, _ b: Int, _ cfg: Config) -> Bool {
        guard a >= 0, b < t.count else { return false }
        let dt = t[b].time.timeIntervalSince(t[a].time)
        if dt <= 0 { return false }
        return Geo.distance(t[a].point, t[b].point) <= cfg.maxSpeedMS * dt + noise(t[a]) + noise(t[b])
    }

    private static func speedText(_ ms: Double) -> String {
        ms > 1000 ? "far beyond any vehicle (over 3,600 km/h)" : String(format: "%.0f km/h", ms * 3.6)
    }
    private static func distText(_ m: Double) -> String { m >= 10_000 ? String(format: "%.0f km", m / 1000) : String(format: "%.0f m", m) }

    // MARK: isolated outliers

    /// Marks fixes that are wrong on their own: far from where BOTH neighbours say the device was, while those
    /// neighbours agree with each other. One bad receiver reading looks like this; a relocation does not, because
    /// the fixes after it stay at the new place and so disagree with the ones before.
    static func isolatedOutliers(_ f: [Fix], _ cfg: Config) -> [Bool] {
        var out = [Bool](repeating: false, count: f.count)
        if f.count < 3 { return out }
        for i in 1..<(f.count - 1) {
            let a = f[i - 1], b = f[i], c = f[i + 1]
            if b.time.timeIntervalSince(a.time) < cfg.minGapForSpeed || c.time.timeIntervalSince(b.time) < cfg.minGapForSpeed { continue }
            if !returnsNear(f, i - 1, i + 1, cfg) { continue }
            let span = c.time.timeIntervalSince(a.time)
            let frac = b.time.timeIntervalSince(a.time) / span
            let expected = GeoPoint(lat: a.point.lat + (c.point.lat - a.point.lat) * frac,
                                    lon: a.point.lon + (c.point.lon - a.point.lon) * frac)
            let off = Geo.distance(b.point, expected)
            out[i] = off > max(50, noise(a) + noise(b) + noise(c))
        }
        return out
    }

    /// Excusing outliers is only safe when there are few of them: 1% of the fixes, and at least 2.
    /// A trace where a sizeable share look like "isolated outliers" has been tampered with, not glitched.
    static func maxExcusedOutliers(_ n: Int) -> Int { max(2, n / 100) }

    /// The fixes that are NOT isolated outliers, as indices into `fixes` (which must be in time order). Used by trip
    /// statistics so a single bad reading cannot anchor a stretch of travel and inflate speed or distance. Public so
    /// the statistics and the verdict share ONE definition of "a bad fix" and can never disagree about it. If more
    /// than a small share look like outliers the trace is treated as tampered with, not glitchy, and none are dropped.
    public static func trustedIndices(_ fixes: [Fix], config: Config = Config()) -> [Int] {
        var bad = isolatedOutliers(fixes, config)
        if bad.filter({ $0 }).count > maxExcusedOutliers(fixes.count) { bad = [Bool](repeating: false, count: fixes.count) }
        return fixes.indices.filter { !bad[$0] }
    }

    // MARK: checks

    static func ordering(_ t: Trace) -> [Finding] {
        var out: [Finding] = []
        let f = t.fixes
        if f.count < 2 { return out }
        for i in 1..<f.count {
            let prev = f[i - 1], cur = f[i]
            if cur.time < prev.time {
                out.append(Finding(check: "ordering", confidence: .medium, line: cur.line, time: cur.time,
                    reason: String(format: "timestamp goes backwards by %.3fs (line %d precedes line %d in time)",
                                   prev.time.timeIntervalSince(cur.time), cur.line, prev.line)))
            } else if cur.time == prev.time, Geo.distance(prev.point, cur.point) > 1 {
                out.append(Finding(check: "ordering", confidence: .medium, line: cur.line, time: cur.time,
                    reason: String(format: "two different positions (%.0f m apart) share one timestamp", Geo.distance(prev.point, cur.point))))
            }
        }
        return out
    }

    static func speed(_ t: Trace, _ cfg: Config) -> [Finding] {
        let f = t.fixes, n = f.count
        if n < 2 { return [] }
        var tooFast = [Bool](repeating: false, count: n)
        var speeds = [Double](repeating: 0, count: n), dists = [Double](repeating: 0, count: n)
        var gaps = [TimeInterval](repeating: 0, count: n)
        for i in 1..<n {
            let dt = f[i].time.timeIntervalSince(f[i - 1].time)
            gaps[i] = dt
            if dt < cfg.minGapForSpeed { continue }
            let d = Geo.distance(f[i - 1].point, f[i].point)
            dists[i] = d
            speeds[i] = max(0, d - noise(f[i - 1]) - noise(f[i])) / dt
            tooFast[i] = speeds[i] > cfg.maxSpeedMS
        }
        var out: [Finding] = []
        for i in 1..<n where tooFast[i] {
            // Return leg of a lone outlier: reported with the outbound leg.
            if i >= 2 && tooFast[i - 1] && returnsNear(f, i - 2, i, cfg) { continue }
            if i + 1 < n && tooFast[i + 1] && returnsNear(f, i - 1, i + 1, cfg) {
                out.append(Finding(check: "speed", confidence: .low, line: f[i].line, time: f[i].time, fixIndex: i,
                    reason: "this fix is a lone outlier: it jumps \(distText(dists[i])) away and the very next fix returns to the earlier track, so this looks like one bad GPS reading, not a relocation"))
                continue
            }
            out.append(Finding(check: "speed", confidence: .high, line: f[i].line, time: f[i].time, fixIndex: i,
                reason: "implied speed \(speedText(speeds[i])) exceeds the plausible maximum of \(String(format: "%.0f", cfg.maxSpeedMS * 3.6)) km/h: \(distText(dists[i])) in \(String(format: "%.1f", gaps[i]))s"))
        }
        return out
    }

    static func teleport(_ t: Trace, _ cfg: Config) -> [Finding] {
        let f = t.fixes, n = f.count
        if n < 2 { return [] }
        var jump = [Bool](repeating: false, count: n)
        for i in 1..<n { jump[i] = Geo.distance(f[i - 1].point, f[i].point) >= cfg.teleportM }
        var out: [Finding] = []
        for i in 1..<n where jump[i] {
            if i >= 2 && jump[i - 1] && returnsNear(f, i - 2, i, cfg) { continue }
            let d = Geo.distance(f[i - 1].point, f[i].point)
            let dt = f[i].time.timeIntervalSince(f[i - 1].time)
            var c = Confidence.medium
            var note = ""
            let lone = i + 1 < n && jump[i + 1] && returnsNear(f, i - 1, i + 1, cfg)
            if lone && d <= maxGlitchM {
                note = ", but the next fix returns to the earlier track, so it looks like a single bad reading"
            } else if lone {
                c = .high
                note = String(format: ", and although the next fix returns, a single-fix error of %.0f km is beyond any receiver glitch", d / 1000)
            } else if dt <= 0 || d / dt > cfg.maxSpeedMS {
                c = .high
                note = ", faster than any plausible vehicle"
            } else if dt > cfg.maxGap {
                note = String(format: " after a %.0fs gap with no fixes in between", dt)
            }
            out.append(Finding(check: "teleport", confidence: c, line: f[i].line, time: f[i].time, fixIndex: i,
                               reason: String(format: "position jumps %.0f km in one step", d / 1000) + note))
        }
        return out
    }

    static func acceleration(_ t: Trace, _ cfg: Config) -> [Finding] {
        struct Seg { let v: Double; let slack: Double; let mid: Date; let fixIndex: Int }
        let f = t.fixes
        var segs: [Seg] = []
        // One bad fix corrupts the speed into it and out of it, and both then look like an acceleration, so
        // build the speeds from the fixes that are NOT isolated outliers (the speed check reports those).
        // Past a small count they stop being excused: that is tampering, not glitching.
        var bad = isolatedOutliers(f, cfg)
        if bad.filter({ $0 }).count > maxExcusedOutliers(f.count) { bad = [Bool](repeating: false, count: f.count) }
        let keep = f.indices.filter { !bad[$0] }
        if keep.count >= 2 {
            for k in 1..<keep.count {
                let i = keep[k], p = keep[k - 1]
                let dt = f[i].time.timeIntervalSince(f[p].time)
                if dt < cfg.minGapForSpeed || dt > cfg.maxGap { continue }
                var n = noise(f[p]) + noise(f[i])
                if f[p].accuracyM == nil || f[i].accuracyM == nil { n = 20 }
                segs.append(Seg(v: Geo.distance(f[p].point, f[i].point) / dt, slack: n / dt,
                                mid: f[p].time.addingTimeInterval(dt / 2), fixIndex: i))
            }
        }
        var out: [Finding] = []
        if segs.count < 2 { return out }
        for i in 1..<segs.count {
            let dt = segs[i].mid.timeIntervalSince(segs[i - 1].mid)
            if dt <= 0 { continue }
            let change = abs(segs[i].v - segs[i - 1].v) - segs[i].slack - segs[i - 1].slack
            if change <= 0 { continue }
            let acc = change / dt
            if acc > cfg.maxAccelMS2 {
                let fx = f[segs[i].fixIndex]
                out.append(Finding(check: "acceleration", confidence: .medium, line: fx.line, time: fx.time, fixIndex: segs[i].fixIndex,
                    reason: String(format: "speed changes from %.1f to %.1f m/s in %.1f s: even after allowing for the reported position error that is %.1f m/s^2, more than the plausible %.0f m/s^2",
                                   segs[i - 1].v, segs[i].v, dt, acc, cfg.maxAccelMS2)))
            }
        }
        return out
    }

    static func accuracy(_ t: Trace) -> [Finding] {
        let vals = t.fixes.compactMap { $0.accuracyM }
        guard vals.count >= minStatPoints, let first = t.fixes.first(where: { $0.accuracyM != nil }),
              let mn = vals.min(), let mx = vals.max() else { return [] }
        var out: [Finding] = []
        if mx < 1.0 {
            out.append(Finding(check: "accuracy", confidence: .medium, line: first.line, time: first.time,
                reason: String(format: "every one of %d fixes claims accuracy under 1 m (max %.2f m); consumer GPS does not achieve that", vals.count, mx)))
        }
        if mx - mn == 0 {
            out.append(Finding(check: "accuracy", confidence: .low, line: first.line, time: first.time,
                reason: String(format: "all %d fixes report exactly the same accuracy (%.1f m); real receivers vary", vals.count, vals[0])))
        }
        return out
    }

    static func smoothness(_ t: Trace) -> [Finding] {
        let f = t.fixes
        guard f.count >= minStatPoints else { return [] }
        var speeds: [Double] = [], headings: [Double] = []
        for i in 1..<f.count {
            let dt = f[i].time.timeIntervalSince(f[i - 1].time)
            if dt <= 0 { continue }
            let d = Geo.distance(f[i - 1].point, f[i].point)
            speeds.append(d / dt)
            if d > 3 { headings.append(Geo.bearing(f[i - 1].point, f[i].point)) }
        }
        guard speeds.count >= minStatPoints - 1, let last = f.last else { return [] }
        var out: [Finding] = []
        let (med, mad) = medianMAD(speeds)
        if med > 0.5 && mad / med < 0.005 {
            out.append(Finding(check: "smoothness", confidence: .medium, line: last.line, time: last.time,
                reason: String(format: "speed is almost perfectly constant (median %.2f m/s, typical variation %.3f%%) across %d intervals; real movement fluctuates", med, 100 * mad / med, speeds.count)))
        }
        if headings.count >= minStatPoints - 1 {
            let cs = circularStdDeg(headings)
            if cs < 0.2 {
                out.append(Finding(check: "smoothness", confidence: .low, line: last.line, time: last.time,
                    reason: String(format: "the heading is a dead-straight line (%.3f deg deviation) over %d moving intervals; real paths wander", cs, headings.count)))
            }
        }
        let mean = speeds.reduce(0, +) / Double(speeds.count)
        if mean < 0.2, f.dropFirst().allSatisfy({ $0.point == f[0].point }) {
            out.append(Finding(check: "smoothness", confidence: .medium, line: last.line, time: last.time,
                reason: "\(f.count) fixes at exactly the same coordinates: a stationary real receiver always drifts by metres"))
        }
        return out
    }

    static func medianMAD(_ v: [Double]) -> (Double, Double) {
        func median(_ s: [Double]) -> Double {
            let a = s.sorted(), n = a.count
            return n == 0 ? 0 : (n % 2 == 1 ? a[n / 2] : (a[n / 2 - 1] + a[n / 2]) / 2)
        }
        let m = median(v)
        return (m, median(v.map { abs($0 - m) }))
    }

    static func circularStdDeg(_ deg: [Double]) -> Double {
        var s = 0.0, c = 0.0
        for d in deg { let r = d * .pi / 180; s += sin(r); c += cos(r) }
        let n = Double(deg.count)
        let R = (s / n * s / n + c / n * c / n).squareRoot()
        return R >= 1 ? 0 : (-2 * log(R)).squareRoot() * 180 / .pi
    }

    /// One impossible jump also looks like a huge speed change on both sides of it; keep only the useful
    /// line. Matching is by fix position, not line number, so it works for live recordings too.
    static func dropExplained(_ fs: [Finding]) -> [Finding] {
        var covered = Set<Int>()
        for f in fs where (f.check == "speed" || f.check == "teleport") && f.fixIndex >= 0 {
            covered.insert(f.fixIndex - 1)   // the step into a jump also "accelerates" up to it
            covered.insert(f.fixIndex)
            covered.insert(f.fixIndex + 1)   // and the step after "accelerates" back down
            covered.insert(f.fixIndex + 2)   // a lone outlier is two jumps (out and back), so one more step
        }
        return fs.filter { !($0.check == "acceleration" && covered.contains($0.fixIndex)) }
    }
}
