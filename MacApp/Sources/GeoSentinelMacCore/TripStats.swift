import Foundation
import GeoSentinelKit

/// Summary figures and per-step speeds for a trace. Pure arithmetic, so it is tested without any UI.
///
/// GPS positions are noisy, and noise inflates both distance (jitter adds path length) and speed (a few metres of
/// error over one second is a few m/s). So two choices are made on purpose:
///   * the headline top speed is the 99th percentile of step speeds, not the maximum, so a single glitch cannot
///     own it;
///   * steps that are jumps (a teleport, a date-line wrap, an impossible speed) are left out of distance and
///     speed, because they are the thing being flagged, not travel. They are counted separately.
public struct TripStats: Equatable {
    public var distanceM: Double          // path length over the plausible steps
    public var duration: TimeInterval     // first fix to last fix
    public var averageSpeedMS: Double     // distanceM / moving duration of plausible steps
    public var topSpeedMS: Double         // 99th percentile of plausible step speeds
    public var fixCount: Int
    public var jumpCount: Int             // steps excluded as jumps
    /// Speed of the step ENDING at each fix, in m/s; index 0 is 0 (no previous fix). Jumps are NaN.
    public var stepSpeeds: [Double]
    /// False when most of the trip moved too little, compared with the GPS error, to measure: the headline figures
    /// would be the luckiest few windows presented as if precise. The UI shows "too little movement to measure"
    /// instead of numbers it cannot stand behind. (A walker with ~13 m of reported error is the typical case.)
    public var reliable: Bool = true

    public var isEmpty: Bool { fixCount < 2 }
}

public enum Stats {
    /// Steps faster than this are treated as jumps, whatever the user's travel mode. 400 m/s is faster than any
    /// aircraft the app is meant for, so anything above it is a position error, not travel.
    public static let jumpSpeedMS = 400.0
    /// A step slower than this is standing still (below the noise floor of GPS), not moving.
    public static let movingThresholdMS = 0.3
    /// At least this share of windows must clear the noise floor for the headline figures to be shown. Below it the
    /// "moving" windows are an unrepresentative few. (honest_walk: 4 of 30 windows cleared it, 13%.)
    public static let minMeasurableShare = 0.5

    /// How long a stretch must be before its distance and speed are trusted. Measured on a real-looking drive (1 Hz,
    /// ~13 m reported error): between adjacent fixes the path came out 47% too long (3,709 m against a 2,521 m
    /// straight line) and the median speed was 0 km/h, because a metre or two of travel per step is buried in 10-20 m
    /// of noise. From 10 s on the length settled (2,647 m at 10 s, 2,592 m at 30 s) and the speeds became coherent.
    public static let windowSeconds = 10.0

    public static func compute(_ trace: Trace) -> TripStats {
        let f = trace.sortedByTime().trace.fixes
        var speeds = [Double](repeating: 0, count: f.count)
        var dist = 0.0, movingTime = 0.0, jumps = 0, weakWindows = 0, movingWindows = 0
        var chordSpeeds: [Double] = []              // chord speed of each window that really moved
        // Windows: from an anchor fix to the first later fix at least `windowSeconds` on (or the last fix, for a
        // short tail). Distance and speed come from the chord between the two ends, so noise averages out instead
        // of adding up.
        // A single bad reading must not anchor a window (one endpoint is worth a whole window, so an 800 m glitch
        // would read as 80 m/s). Window over the TRUSTED fixes only, using the detector's own definition of a bad
        // fix, so the statistics and the verdict can never disagree about which readings are wrong. Fixes that are
        // left out get no speed (NaN), so the map does not draw a coloured path through them.
        let trusted = Detector.trustedIndices(f)
        let kept = Set(trusted)
        for k in f.indices where !kept.contains(k) { speeds[k] = .nan }

        var a = 0                                   // position within `trusted`
        while a < trusted.count - 1 {
            var b = a + 1
            while b < trusted.count - 1 && f[trusted[b]].time.timeIntervalSince(f[trusted[a]].time) < windowSeconds { b += 1 }
            let i = trusted[a], j = trusted[b]
            let dt = f[j].time.timeIntervalSince(f[i].time)
            let d = Geo.distance(f[i].point, f[j].point)
            guard dt > 0 else {
                // fixes at one instant: no speed to speak of; a displacement is a jump, a repeat is nothing
                if d > 1 { jumps += 1; for k in (i + 1)...j { speeds[k] = .nan } }
                a = b
                continue
            }
            // Two different questions, answered from two different numbers on purpose:
            //   * CLASSIFYING a window (is it a jump? is the device moving at all?) uses the speed after forgiving the
            //     noise the device reported (same rule as the detector, capped at 200 m per fix): a conservative test.
            //   * REPORTING (distance, average, top speed) uses the raw chord speed, which is an unbiased estimate: over
            //     10 s the noise averages out, whereas subtracting it shaved ~600 m off a drive whose path cannot be
            //     shorter than its 2,521 m straight line. (Reporting the forgiven number made the distance impossible.)
            // All three reported figures come from the SAME chord speeds, so the average can never exceed the top.
            let slack = min(f[i].accuracyM ?? 0, 200) + min(f[j].accuracyM ?? 0, 200)
            let forgiven = max(0, d - slack) / dt
            let chord = d / dt
            if forgiven > jumpSpeedMS {
                jumps += 1
                for k in (i + 1)...j { speeds[k] = .nan }       // the jump is flagged, not counted as travel
            } else if forgiven >= Stats.movingThresholdMS {
                for k in (i + 1)...j where kept.contains(k) { speeds[k] = chord }   // each trusted fix shares its window's speed
                chordSpeeds.append(chord)
                dist += d; movingTime += dt                      // only windows that really moved: a standstill is not "moving time"
                movingWindows += 1
            } else {
                for k in (i + 1)...j where kept.contains(k) { speeds[k] = 0 }       // too slow to tell from GPS noise
                weakWindows += 1
            }
            a = b
        }
        let duration = f.count >= 2 ? f[f.count - 1].time.timeIntervalSince(f[0].time) : 0
        // How reliable are these figures? If most windows are too slow to separate from GPS noise (a walker with ~13 m
        // of reported error moves about 14 m in a 10 s window, less than the error), the surviving "moving" windows
        // are just the luckiest ones, and the figures would look precise while being wrong. Say so instead.
        // A trace where NO window moved at all is a standstill: a clear answer ("did not move"), not an unmeasurable
        // one. The unreliable case is the in-between: some windows clear the floor, but most do not.
        let windowsTotal = movingWindows + weakWindows
        let measurable = windowsTotal > 0 && Double(movingWindows) / Double(windowsTotal) >= Stats.minMeasurableShare
        // "Nothing moved" and "too noisy to tell" both produce all-weak windows, but they are opposite answers. Tell
        // them apart by the whole trace: a real standstill ends within the GPS error of where it began, while a slow
        // walk with large error has gone somewhere (here 14 m x 30 windows = 420 m against about 20 m of error).
        // (Indexing `f` with a fallback of 0 crashed on an empty trace: an empty array has no element 0. Only look at
        // the ends when there are at least two trusted fixes.)
        var wentSomewhere = false
        if let first = trusted.first, let last = trusted.last, trusted.count >= 2 {
            let netDisplacement = Geo.distance(f[first].point, f[last].point)
            let reportedError = (f[first].accuracyM ?? 0) + (f[last].accuracyM ?? 0)
            wentSomewhere = netDisplacement > max(2 * reportedError, 50)
        }
        let standstill = windowsTotal > 0 && movingWindows == 0 && !wentSomewhere
        return TripStats(
            distanceM: dist, duration: max(0, duration),
            averageSpeedMS: movingTime > 0 ? dist / movingTime : 0,
            topSpeedMS: percentile(chordSpeeds, 0.99),
            fixCount: f.count, jumpCount: jumps, stepSpeeds: speeds,
            reliable: measurable || windowsTotal == 0 || standstill)
    }

    /// The p-quantile (0...1) of values by linear interpolation; 0 for no values.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        let v = values.filter { $0.isFinite }.sorted()
        guard !v.isEmpty else { return 0 }
        if v.count == 1 { return v[0] }
        let pos = min(max(p, 0), 1) * Double(v.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, v.count - 1)
        return v[lo] + (v[hi] - v[lo]) * (pos - Double(lo))
    }

    // MARK: formatting (kept here so the strings are tested)

    public static func distanceText(_ m: Double) -> String {
        if m < 1000 { return String(format: "%.0f m", m) }
        if m < 100_000 { return String(format: "%.1f km", m / 1000) }
        return String(format: "%.0f km", m / 1000)
    }

    public static func durationText(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(t) s" }
        if t < 3600 { return "\(t / 60) min \(t % 60) s" }
        return "\(t / 3600) h \((t % 3600) / 60) min"
    }

    public static func speedText(_ ms: Double) -> String { String(format: "%.0f km/h", ms * 3.6) }
}

/// A single-hue (blue) ramp for speed: light is slow, dark is fast. One hue and a strictly monotone lightness mean
/// "darker = faster" reads correctly at a glance and survives colour-blindness (a rainbow would not). The ends are
/// chosen so even the lightest step stays visible on a white or dark map background.
public enum SpeedRamp {
    /// (r, g, b) in 0...1, slowest to fastest. Lightness falls at every step.
    public static let steps: [(r: Double, g: Double, b: Double)] = [
        (0.62, 0.77, 0.96), (0.43, 0.66, 0.93), (0.22, 0.53, 0.90), (0.15, 0.42, 0.75), (0.10, 0.32, 0.58), (0.05, 0.21, 0.42),
    ]

    /// Relative luminance (Rec. 709 weights) used to check the ramp is monotone.
    public static func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

    /// Colour for `speed` given the fastest speed on the ramp (`top`). Interpolates between steps; NaN, negative or
    /// zero `top` give the slowest colour, and anything above `top` gives the fastest.
    public static func colour(speed: Double, top: Double) -> (r: Double, g: Double, b: Double) {
        guard speed.isFinite, top.isFinite, top > 0, speed > 0 else { return steps[0] }
        let x = min(speed / top, 1) * Double(steps.count - 1)
        let i = min(Int(x), steps.count - 2), f = x - Double(i)
        let a = steps[i], b = steps[i + 1]
        return (a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f)
    }
}

/// Where along a trace the replay marker is, for a fraction `t` in 0...1 of the elapsed time. The marker rides
/// the RECORDED positions (interpolated between two real fixes); it never produces a position that is not in the
/// file. Returns the index of the fix at or before that moment and how far (0...1) toward the next one.
public func replayPosition(_ fixes: [Fix], fraction t: Double) -> (index: Int, along: Double)? {
    guard let first = fixes.first, let last = fixes.last, fixes.count >= 2 else { return fixes.isEmpty ? nil : (0, 0) }
    let total = last.time.timeIntervalSince(first.time)
    guard total > 0, t.isFinite else { return (0, 0) }
    let target = first.time.addingTimeInterval(min(max(t, 0), 1) * total)
    // binary search for the last fix at or before the target time
    var lo = 0, hi = fixes.count - 1
    while lo < hi {
        let mid = (lo + hi + 1) / 2
        if fixes[mid].time <= target { lo = mid } else { hi = mid - 1 }
    }
    if lo >= fixes.count - 1 { return (fixes.count - 1, 0) }
    let span = fixes[lo + 1].time.timeIntervalSince(fixes[lo].time)
    let along = span > 0 ? target.timeIntervalSince(fixes[lo].time) / span : 0
    return (lo, min(max(along, 0), 1))
}

/// Advances the replay fraction for a trip of `duration` seconds. Pure arithmetic so it is tested without a timer.
/// A trip is replayed at `speedup` times real time but never faster than it takes to watch: a 10-hour trip would
/// otherwise take forever, and a 5-second one would flash by, so the replay always lasts between 6 and 40 seconds.
public func replayStep(fraction: Double, durationSeconds: Double, dt: Double) -> Double {
    guard durationSeconds.isFinite, durationSeconds > 0, dt.isFinite, dt > 0, fraction.isFinite else { return 1 }
    let watchSeconds = min(max(durationSeconds, 6), 40)       // how long the replay should take
    return min(1, max(0, fraction) + dt / watchSeconds)
}
