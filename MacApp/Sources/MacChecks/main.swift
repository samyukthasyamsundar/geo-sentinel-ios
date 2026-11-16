import Foundation
import GeoSentinelKit
import GeoSentinelMacCore

var failures = 0, total = 0
func check(_ ok: Bool, _ msg: String, line: UInt = #line) { total += 1; if !ok { failures += 1; print("FAIL: \(msg)  (line \(line))") } }
func near(_ a: Double, _ b: Double, _ tol: Double, _ msg: String, line: UInt = #line) { check(abs(a - b) <= tol, "\(msg): got \(a), want \(b)", line: line) }

func fix(_ lat: Double, _ lon: Double, _ t: Double = 0) -> Fix { Fix(point: GeoPoint(lat: lat, lon: lon), time: Date(timeIntervalSince1970: 1_700_000_000 + t)) }
let aspect = 1.6

// ---------------- MapProjection ----------------
do {
    // a normal local trace: every point lands inside the box, and the box keeps its aspect ratio
    let fixes = (0..<50).map { fix(47.60 + Double($0) * 0.0002, -122.33 + Double($0) * 0.0003, Double($0)) }
    let p = MapProjection(fixes: fixes, aspect: aspect)
    for f in fixes {
        let pt = p.point(f.point, width: 800, height: 500)
        check(pt.x >= 0 && pt.x <= 800 && pt.y >= 0 && pt.y <= 500, "point inside the box: \(pt)")
    }
    // north is up: a higher latitude has a SMALLER y
    check(p.point(GeoPoint(lat: 47.61, lon: -122.33), width: 800, height: 500).y < p.point(GeoPoint(lat: 47.60, lon: -122.33), width: 800, height: 500).y, "north is up")
    check(p.point(GeoPoint(lat: 47.60, lon: -122.32), width: 800, height: 500).x > p.point(GeoPoint(lat: 47.60, lon: -122.33), width: 800, height: 500).x, "east is right")
    // the box has the requested shape on the ground (lon span scaled by cos(lat))
    let ground = (p.maxLon - p.minLon) * cos(47.6 * .pi / 180) / (p.maxLat - p.minLat)
    near(ground, aspect, 0.01, "box aspect on the ground")
}
do { // a single point, and many identical points: must produce a finite, non-degenerate box
    for fixes in [[fix(47.6, -122.3)], Array(repeating: fix(47.6, -122.3), count: 20)] {
        let p = MapProjection(fixes: fixes, aspect: aspect)
        check(p.maxLat > p.minLat && p.maxLon > p.minLon, "non-degenerate box for \(fixes.count) identical point(s)")
        check([p.minLat, p.maxLat, p.minLon, p.maxLon].allSatisfy { $0.isFinite }, "finite box")
        let pt = p.point(fixes[0].point, width: 800, height: 500)
        near(pt.x, 400, 1, "single point centred in x"); near(pt.y, 250, 1, "single point centred in y")
    }
}
do { // the date line: neighbours either side of it must be neighbours on the map
    // Measure what matters: the pixel gap must equal the true gap scaled by the box, and both must be INSIDE
    // the box. (Without unwrapping, the points would land at opposite edges, ~full width apart.)
    for halfGapDeg in [0.0005, 0.5, 5.0] {
        let a = fix(0, 180 - halfGapDeg), b = fix(0, -180 + halfGapDeg, 1)
        let p = MapProjection(fixes: [a, b], aspect: aspect)
        let pa = p.point(a.point, width: 800, height: 500), pb = p.point(b.point, width: 800, height: 500)
        let boxWidthDeg = p.maxLon - p.minLon
        let expectedGapPx = (2 * halfGapDeg) / boxWidthDeg * 800
        near(abs(pb.x - pa.x), expectedGapPx, 0.5, "date-line gap of \(2 * halfGapDeg) deg is the right pixel gap")
        check(pa.x >= 0 && pa.x <= 800 && pb.x >= 0 && pb.x <= 800, "both date-line points are inside the box (\(pa.x), \(pb.x))")
        check(pb.x > pa.x, "east of the date line is to the right")
    }
}
do { // near the pole the box must stay on the globe and the labels must make sense
    let p = MapProjection(fixes: [fix(89.9, 0), fix(89.95, 10, 1)], aspect: aspect)
    check(p.maxLat <= 90 + 1e-9 && p.minLat >= -90 - 1e-9, "box stays on the globe at the pole: \(p.minLat)...\(p.maxLat)")
    check([p.minLat, p.maxLat, p.minLon, p.maxLon].allSatisfy { $0.isFinite }, "finite near the pole")
}
do { // an intercontinental trace: latitude range stays sensible (this was a real bug: it ran to the pole)
    let p = MapProjection(fixes: [fix(47.6, -122.3), fix(48.9, 2.4, 1)], aspect: 1.85)
    check(p.maxLat - p.minLat <= 61, "intercontinental latitude range is not absurd: \(p.maxLat - p.minLat) degrees")
    check(p.maxLat < 90, "does not run into the pole: \(p.maxLat)")
}

// Surviving mutations from the first pass, closed with tests that pin the exact behaviour:
do { // M1: the BOX must unwrap the date line, not just each point. Without it the box spans ~360 degrees.
    let p = MapProjection(fixes: [fix(0, 179.9), fix(0, -179.9, 1)], aspect: aspect)
    check(p.maxLon - p.minLon < 1.0, "a date-line trace gets a small box, not a world-wide one: \(p.maxLon - p.minLon) deg wide")
    check(p.minLon > 179 && p.maxLon < 181, "the box is centred on the date line (\(p.minLon) ... \(p.maxLon))")
}
do { // M4: near the pole the box is SHIFTED onto the globe, so its height survives (not cut at 90)
    // Compare against the same trace moved well away from the pole: a box that was merely CUT at 90 would be
    // shorter than the unclamped one, a box that was SHIFTED has exactly the same height.
    // Contract near a pole (this replaced an earlier one that "shifted" the box back onto the globe, which left the
    // data jammed against the map's edge; a walk at 89.95 N ran along the very top of the picture):
    //   1. the box stays centred on the data, 2. it never goes beyond a pole, 3. it is not a degenerate sliver.
    for (name, lats) in [("north", [89.9, 89.99]), ("south", [-89.9, -89.99])] {
        let p = MapProjection(fixes: [fix(lats[0], 0), fix(lats[1], 5, 1)], aspect: aspect)
        let centre = (p.maxLat + p.minLat) / 2, dataCentre = (lats[0] + lats[1]) / 2
        near(centre, dataCentre, 1e-9, "\(name) pole: the box stays centred on the data (\(centre) vs \(dataCentre))")
        check(p.maxLat <= 90 + 1e-12 && p.minLat >= -90 - 1e-12, "\(name) pole: the box stays on the globe (\(p.minLat) ... \(p.maxLat))")
        check(p.maxLat - p.minLat > 0.05, "\(name) pole: the box is not a degenerate sliver (\(p.maxLat - p.minLat))")
        // the data must sit well inside the box, not on its edge
        let top = p.point(GeoPoint(lat: max(lats[0], lats[1]), lon: 0), width: 800, height: 500).y
        let bottom = p.point(GeoPoint(lat: min(lats[0], lats[1]), lon: 0), width: 800, height: 500).y
        check(top > 40 && bottom < 460, "\(name) pole: the data is not jammed against an edge (y \(top) ... \(bottom) of 500)")
    }
    // Away from the poles the box is unchanged: a trace at 10 N keeps its full padded, aspect-corrected height.
    let inMiddle = MapProjection(fixes: [fix(10.0, 0), fix(10.09, 5, 1)], aspect: aspect)
    near(inMiddle.maxLat - inMiddle.minLat, 3.8156, 0.01, "away from the poles the box height is unchanged (\(inMiddle.maxLat - inMiddle.minLat))")
}
do { // M5: a very wide trace must be held to 60 degrees of latitude (it ran to the pole before)
    // Seattle to Sydney spans ~275 degrees of longitude: wide enough that the cap, not the aspect ratio, decides.
    let wide = MapProjection(fixes: [fix(47.6, -122.3), fix(-33.9, 151.2, 1)], aspect: 1.85)
    check(wide.maxLat - wide.minLat <= 120.001, "an extremely wide trace still fits on the globe: \(wide.maxLat - wide.minLat)")
    // Seattle to Paris is wide but under the cap: the range follows the aspect ratio (about 56 degrees), < 60
    let sp = MapProjection(fixes: [fix(47.6, -122.3), fix(48.9, 2.4, 1)], aspect: 1.85)
    check(sp.maxLat - sp.minLat < 60 && sp.maxLat - sp.minLat > 50, "Seattle-Paris range is sensible: \(sp.maxLat - sp.minLat)")
    check(sp.maxLat < 80, "and does not run into the pole (this was the real bug: it reached 90): \(sp.maxLat)")
    // Where the cap decides: a SQUARER window (a user narrowing the window) would want a box ~103 degrees tall for
    // this trace (taller than the planet allows); the cap holds it to 60.
    for narrowAspect in [1.0, 0.8, 0.5] {
        let capped = MapProjection(fixes: [fix(47.6, -122.3), fix(48.9, 2.4, 1)], aspect: narrowAspect)
        near(capped.maxLat - capped.minLat, 60, 0.001, "aspect \(narrowAspect): the cap holds the range to exactly 60")
        near((capped.maxLat + capped.minLat) / 2, 48.25, 0.01, "aspect \(narrowAspect): and it stays centred on the data")
        check(capped.maxLat < 90 && capped.minLat > -90, "aspect \(narrowAspect): and stays on the globe")
    }
    // A wider window needs a SHORTER box, so the cap is not involved and the range shrinks as the window widens
    let w3 = MapProjection(fixes: [fix(47.6, -122.3), fix(48.9, 2.4, 1)], aspect: 3.0)
    check(w3.maxLat - w3.minLat < sp.maxLat - sp.minLat, "a wider window gets a shorter box: \(w3.maxLat - w3.minLat)")
    let narrow = MapProjection(fixes: [fix(47.6, -122.3), fix(47.7, -122.2, 1)], aspect: 1.85)
    check(narrow.maxLat - narrow.minLat < 1, "a local trace is NOT stretched: \(narrow.maxLat - narrow.minLat)")
}

// ---------------- grouping of findings ----------------
do {
    func f(_ r: String, _ idx: Int, check: String = "speed", c: Confidence = .high) -> Finding {
        Finding(check: check, confidence: c, line: 0, time: Date(timeIntervalSince1970: Double(idx)), fixIndex: idx, reason: r)
    }
    let g = grouped([f("same", 3), f("other", 4), f("same", 5), f("same", 9)])
    check(g.count == 2, "four findings with two distinct reasons become two rows: \(g.count)")
    check(g[0].fixIndices == [3, 5, 9] && g[0].count == 3, "the repeated row keeps every position and counts them: \(g[0].fixIndices)")
    check(g[0].reason.hasSuffix("(3 times)"), "the repeated row says how many: \(g[0].reason)")
    check(g[1].reason == "other" && g[1].count == 1, "a unique row is left alone: \(g[1].reason)")
    check(g.map { $0.reason.hasPrefix("same") ? 0 : 1 } == [0, 1], "order follows first occurrence")
    check(grouped([f("x", 1, c: .low), f("x", 2, c: .high)]).count == 2, "the same text at different confidence is NOT merged")
    check(grouped([f("x", 1, check: "speed"), f("x", 2, check: "teleport")]).count == 2, "the same text from different checks is NOT merged")
    check(grouped([]).isEmpty, "no findings, no rows")
    let nofix = grouped([f("note", -1), f("note", -1)])
    check(nofix.count == 1 && nofix[0].fixIndices.isEmpty && nofix[0].count == 1, "findings with no position still group without a crash")
}

// ---------------- trackSegments ----------------
do {
    let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 900, y: 0), CGPoint(x: 910, y: 0)]
    let segs = trackSegments(pts, breakDistance: 400)
    check(segs.count == 2 && segs[0].count == 3 && segs[1].count == 2, "a jump splits the path into two segments: \(segs.map { $0.count })")
    check(trackSegments([], breakDistance: 10).isEmpty, "empty in, empty out")
    check(trackSegments([CGPoint(x: 1, y: 1)], breakDistance: 10).count == 1, "one point is one segment")
    check(trackSegments(pts, breakDistance: 1e9).count == 1, "no break when the threshold is huge")
}

// ---------------- Loader ----------------
/// Builds a CSV with one row per second, moving north by `metersPerSecond`.
func makeCSV(count: Int, metersPerSecond: Double) -> String {
    var out: String = "time,lat,lon,accuracy\n"
    for i in 0..<count {
        let minute: Int = i / 60
        let second: Int = i % 60
        let lat: Double = 47.0 + Double(i) * metersPerSecond / 111_195.0
        let acc: Double = 5.0 + Double(i % 7)
        out += String(format: "2026-11-12T10:%02d:%02dZ,%.7f,%.7f,%.1f\n", minute, second, lat, -122.3, acc)
    }
    return out
}
let goodCSV: String = makeCSV(count: 60, metersPerSecond: 1.5)
func ok(_ r: Result<Analysis, Loader.Failure>) -> Analysis? { if case .success(let a) = r { return a }; return nil }
func fail(_ r: Result<Analysis, Loader.Failure>) -> Loader.Failure? { if case .failure(let f) = r { return f }; return nil }

if let a = ok(Loader.analyse(data: Data(goodCSV.utf8), fileName: "t.csv", ext: "csv", speed: .car)) {
    check(a.trace.fixes.count == 60 && a.fileName == "t.csv", "good CSV loads")
} else { check(false, "good CSV should analyse") }

check(fail(Loader.analyse(data: Data("time,lat,lon\n2026-11-12T10:00:00Z,north,2\n".utf8), fileName: "x.csv", ext: "csv", speed: .car))?.description.contains("line 2") == true, "parse errors carry the line number")
check(fail(Loader.analyse(data: Data("hello".utf8), fileName: "x.gpx", ext: "gpx", speed: .car)) != nil, "bad GPX is a failure, not a crash")
check(fail(Loader.analyse(data: Data([0xff, 0xfe, 0x00, 0x80]), fileName: "x.csv", ext: "csv", speed: .car)) != nil, "binary garbage is a failure, not a crash")

// url-based entry point: type check, missing file, directory
let tmp = FileManager.default.temporaryDirectory
let txt = tmp.appendingPathComponent("mc_notes.txt"); try? Data("x".utf8).write(to: txt)
check(fail(Loader.analyse(url: txt, speed: .car)) == .unsupportedType("txt"), "a .txt file is refused by type")
check(fail(Loader.analyse(url: tmp.appendingPathComponent("mc_nofile.csv"), speed: .car)) != nil, "a missing file is a failure")
check(fail(Loader.analyse(url: URL(fileURLWithPath: "/tmp"), speed: .car)) != nil, "a directory is a failure, not a crash")
check(fail(Loader.analyse(url: tmp.appendingPathComponent("noextension"), speed: .car)) == .unsupportedType(""), "no extension is refused with a clear message")
check(Loader.Failure.unsupportedType("").description.contains("no extension"), "the no-extension message says so")
try? FileManager.default.removeItem(at: txt)

// out-of-range coordinates are reported, not drawn
check(fail(Loader.analyse(data: Data("time,lat,lon\n1700000000,95,2\n1700000001,10,10\n".utf8), fileName: "r.csv", ext: "csv", speed: .car))?.description.contains("out of range") == true, "coordinates out of range are reported")

// ---------------- speed presets: the same trace is judged by the mode the user picked ----------------
// a 200 km/h run (55.6 m/s) for 5 minutes: fine for a train or aircraft, impossible for a car, absurd on foot
let fast: String = makeCSV(count: 300, metersPerSecond: 55.6)
func verdict(_ p: SpeedPreset) -> Verdict? { ok(Loader.analyse(data: Data(fast.utf8), fileName: "fast.csv", ext: "csv", speed: p))?.verdict }
check(verdict(.onFoot) == .likelySpoofed, "200 km/h on foot is impossible: \(String(describing: verdict(.onFoot)))")
check(verdict(.car) != .likelySpoofed, "200 km/h is plausible for a car limit of 306 km/h: \(String(describing: verdict(.car)))")
check(verdict(.train) != .likelySpoofed && verdict(.aircraft) != .likelySpoofed, "and for a train or aircraft")
check(SpeedPreset.allCases.map { $0.kmh } == [60, 306, 450, 1200], "preset limits are as documented")
check(SpeedPreset.allCases.map { $0.kmh } == SpeedPreset.allCases.map { $0.kmh }.sorted(), "presets are ordered slowest to fastest")

// ---------------- summary text ----------------
func a(_ v: Verdict, findings n: Int) -> Analysis {
    Analysis(fileName: "f", trace: Trace(fixes: (0..<5).map { fix(1, 1, Double($0)) }),
             findings: (0..<n).map { _ in Finding(check: "speed", confidence: .low, line: 0, time: Date(), reason: "r") }, verdict: v)
}
check(summary(for: a(.clean, findings: 0)).contains("Nothing impossible"), "clean summary")
check(summary(for: a(.clean, findings: 1)).contains("one note"), "singular note wording")
check(summary(for: a(.clean, findings: 3)).contains("3 notes"), "plural notes wording")
check(summary(for: a(.suspicious, findings: 2)).contains("none is conclusive"), "suspicious summary does not accuse")
check(summary(for: a(.likelySpoofed, findings: 2)).contains("no real device"), "spoofed summary")

// ---------------- TripStats ----------------
func runTrace(_ n: Int, metersPerSecond v: Double, accuracy: Double? = nil, startLat: Double = 10) -> Trace {
    Trace(fixes: (0..<n).map { i in
        Fix(point: GeoPoint(lat: startLat + Double(i) * v / 111_194.93, lon: 20), time: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), accuracyM: accuracy, line: i + 2)
    })
}
do {
    // 101 fixes, 1 s apart, steady 10 m/s => 100 steps, 1000 m, 100 s, speed exactly 10 m/s
    let s = Stats.compute(runTrace(101, metersPerSecond: 10))
    near(s.distanceM, 1000, 1.0, "steady run: distance")
    near(s.duration, 100, 1e-9, "steady run: duration")
    near(s.averageSpeedMS, 10, 0.01, "steady run: average speed")
    near(s.topSpeedMS, 10, 0.01, "steady run: top speed")
    check(s.fixCount == 101 && s.jumpCount == 0, "steady run: no jumps (\(s.jumpCount))")
    check(s.stepSpeeds.count == 101 && s.stepSpeeds[0] == 0, "one speed per fix, the first being 0")
    check(!s.isEmpty, "a 101-fix trace is not empty")
}
do { // a teleport must NOT turn into a 8000 km "distance" or a mach-20 top speed
    var fixes = runTrace(60, metersPerSecond: 10).fixes
    for i in 30..<60 { fixes[i].point = GeoPoint(lat: fixes[i].point.lat + 70, lon: 120) }   // jump thousands of km and stay
    let s = Stats.compute(Trace(fixes: fixes))
    check(s.jumpCount == 1, "one jump step is excluded (\(s.jumpCount))")
    check(s.distanceM < 1000, "the jump adds no distance: \(s.distanceM) m")
    check(s.topSpeedMS < 20, "the jump does not own the top speed: \(s.topSpeedMS) m/s")
    check(s.stepSpeeds.contains { $0.isNaN }, "the jump step is marked (NaN) for the map")
}
do { // one GPS glitch must not own the headline top speed (that is why it is the 99th percentile)
    var fixes = runTrace(201, metersPerSecond: 10).fixes
    fixes[100].point = Geo.destination(fixes[100].point, bearing: 90, meters: 800)    // one 800 m glitch: ~800 m/s each way => jumps
    let s = Stats.compute(Trace(fixes: fixes))
    check(s.topSpeedMS < 30, "one glitch does not set the top speed: \(s.topSpeedMS) m/s")
    // The glitch is dropped as an isolated OUTLIER before any window is formed (the same definition the verdict
    // uses), so it never becomes a "jump" and cannot anchor a window and read as 80 m/s.
    check(s.jumpCount == 0, "a lone glitch is an outlier, not a jump (\(s.jumpCount) jumps)")
    let trusted = Detector.trustedIndices(fixes)
    check(trusted.count == 200 && !trusted.contains(100), "exactly the glitch fix (100) is the one left out: \(201 - trusted.count) dropped")
    check(s.stepSpeeds[100].isNaN, "and it carries no speed, so the map draws no coloured path through it")
    near(s.distanceM, 2000, 60, "distance is the real travel (200 steps at 10 m/s), not inflated by the glitch: \(s.distanceM)")
}
do { // S1: the headline top speed is a high percentile, so one brief fast stretch cannot own it.
    // 200 steps at 10 m/s, with a one-step 290 m displacement at fix 101 that then CONTINUES from the new place
    // (a small relocation, not a lone glitch, so it is not dropped as an outlier). Speeds are measured over
    // 10-second windows, which dilutes a one-second event of 300 m/s to about 33 m/s: measuring GPS over adjacent
    // fixes just reads noise (that gave a 47% overlong path on a real-looking drive), so a blip is smoothed, by design.
    var fixes = runTrace(201, metersPerSecond: 10).fixes
    for i in 101..<201 { fixes[i].point = GeoPoint(lat: fixes[i].point.lat + 290.0 / 111_194.93, lon: fixes[i].point.lon) }
    let s = Stats.compute(Trace(fixes: fixes))
    check(s.jumpCount == 0, "the 10-second window containing the step is 30 m/s, far under the jump threshold (\(s.jumpCount) jumps)")
    check(s.stepSpeeds.contains { $0 > 25 && $0 < 45 }, "the event shows up, smoothed over its window, as about 30 m/s: max \(s.stepSpeeds.filter { $0.isFinite }.max() ?? -1)")
    check(!s.stepSpeeds.contains { $0.isFinite && $0 > 100 }, "no single second is reported as hundreds of m/s")
    check(s.topSpeedMS < 40, "one brief event does not drive the top speed to the raw 300 m/s: \(s.topSpeedMS) m/s")
    // ...but a SUSTAINED fast stretch (5% of the trip) does show up, since it is real
    var sustained = runTrace(201, metersPerSecond: 10).fixes
    var extra = 0.0
    for i in 1..<201 { if i >= 100 && i < 120 { extra += 40 }; sustained[i].point = GeoPoint(lat: sustained[i].point.lat + extra / 111_194.93, lon: 20) }
    let s2 = Stats.compute(Trace(fixes: sustained))
    check(s2.topSpeedMS > 40, "a sustained fast stretch is reflected in the top speed: \(s2.topSpeedMS) m/s")
}
do { // S6: average speed is distance over MOVING time, so a long pause does not drag it down
    // 50 steps at 10 m/s, then a 1000 s gap with the device standing still, then 50 more steps at 10 m/s.
    var fixes: [Fix] = []
    var lat = 10.0, t = 0.0
    for i in 0..<101 {
        if i == 51 { t += 1000 }                       // a long pause: same position, much later
        fixes.append(Fix(point: GeoPoint(lat: lat, lon: 20), time: Date(timeIntervalSince1970: 1_700_000_000 + t), accuracyM: nil, line: i + 2))
        if i != 50 { lat += 10.0 / 111_194.93 }
        t += 1
    }
    let s = Stats.compute(Trace(fixes: fixes))
    check(s.duration > 1000, "the trip really lasted over 1000 s: \(s.duration)")
    near(s.averageSpeedMS, 10, 1.0, "average speed ignores the long standstill (moving time, not wall time): \(s.averageSpeedMS) m/s")
}
do { // REGRESSION: found by looking at a screenshot. On a real-looking noisy drive the first version of the stats
    // reported "Average 61 km/h, Top speed 33 km/h" (an average above the top, impossible) and a 611 m distance,
    // because per-step speed over 1 Hz GPS with ~13 m of error is mostly noise. Checked against the same trace
    // measured independently in Python: the straight line start-to-end is 2,521 m and the 10-second-window path 2,647 m.
    if let url = Optional(URL(fileURLWithPath: "../TestData/honest_drive.csv")), let data = try? Data(contentsOf: url),
       let trace = try? CSVParser.parse(data) {
        let s = Stats.compute(trace)
        check(s.averageSpeedMS <= s.topSpeedMS + 1e-9, "the average (\(Stats.speedText(s.averageSpeedMS))) never exceeds the top speed (\(Stats.speedText(s.topSpeedMS)))")
        check(s.distanceM > 2521 && s.distanceM < 3000, "distance is between the straight line (2521 m) and a sane path length: \(s.distanceM) m")
        near(s.duration, 299, 1, "the drive lasted 299 seconds")
        check(s.averageSpeedMS * 3.6 > 20 && s.averageSpeedMS * 3.6 < 45, "average speed is a believable drive: \(Stats.speedText(s.averageSpeedMS))")
        check(s.topSpeedMS * 3.6 < 70, "top speed is believable: \(Stats.speedText(s.topSpeedMS))")
        check(s.jumpCount == 0, "an honest drive has no jumps (\(s.jumpCount))")
    } else { check(false, "could not load ../TestData/honest_drive.csv (run from the MacApp folder)") }
    // ...and for every example trace the average never exceeds the top speed
    for name in ["honest_drive", "honest_walk", "fake_frozen", "fake_scripted", "fake_careful", "fake_teleport"] {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "../TestData/\(name).csv")), let t = try? CSVParser.parse(data) {
            let s = Stats.compute(t)
            check(s.averageSpeedMS <= s.topSpeedMS + 1e-9 && s.distanceM.isFinite && s.topSpeedMS.isFinite, "\(name): average \(Stats.speedText(s.averageSpeedMS)) <= top \(Stats.speedText(s.topSpeedMS))")
            // which traces are measurable is a property of the data: a walker with 13 m of GPS error cannot be measured
            // over 10-second windows (about 14 m of travel against 27 m of forgiven error), so it must say so
            let expectReliable = name != "honest_walk"
            check(s.reliable == expectReliable, "\(name): reliable == \(s.reliable), expected \(expectReliable)")
        } else { check(false, "could not load \(name)") }
    }
}
do { // reliability: say "cannot measure" instead of showing precise-looking wrong numbers
    // a standstill is a clear answer, not an unmeasurable one
    let still = Trace(fixes: (0..<120).map { i in Fix(point: GeoPoint(lat: 10, lon: 20), time: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), accuracyM: 5, line: i + 2) })
    let st = Stats.compute(still)
    check(st.reliable && st.topSpeedMS == 0 && st.distanceM == 0, "a standstill is reliably zero: reliable=\(st.reliable) top=\(st.topSpeedMS) dist=\(st.distanceM)")
    // a steady drive with modest noise is measurable
    check(Stats.compute(runTrace(200, metersPerSecond: 12, accuracy: 8)).reliable, "a steady 12 m/s drive with 8 m error is measurable")
    // a slow walker with large reported error is not: 1.4 m/s over 10 s is 14 m, less than the 2 x 20 m forgiven
    let walker = Trace(fixes: (0..<300).map { i in
        Fix(point: GeoPoint(lat: 10 + Double(i) * 1.4 / 111_194.93, lon: 20), time: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), accuracyM: 20, line: i + 2) })
    let ws = Stats.compute(walker)
    check(!ws.reliable, "a 1.4 m/s walk with 20 m error cannot be measured over 10 s windows (reliable=\(ws.reliable))")
    check(ws.distanceM == 0 && ws.topSpeedMS == 0, "and it reports no invented figures: dist \(ws.distanceM), top \(ws.topSpeedMS)")
    // a walk that went NOWHERE (back and forth within the error) is a standstill, and that is a clear answer
    let pacing = Trace(fixes: (0..<300).map { i in
        Fix(point: GeoPoint(lat: 10 + (i % 20 < 10 ? 1 : -1) * Double(i % 10) * 1.4 / 111_194.93, lon: 20), time: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), accuracyM: 20, line: i + 2) })
    let ps = Stats.compute(pacing)
    check(ps.reliable && ps.topSpeedMS == 0, "pacing within the GPS error is a reliable standstill: reliable=\(ps.reliable) top=\(ps.topSpeedMS)")
    // ...but the same walk with a good fix (4 m error) can
    let careful = Trace(fixes: (0..<300).map { i in
        Fix(point: GeoPoint(lat: 10 + Double(i) * 1.4 / 111_194.93, lon: 20), time: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), accuracyM: 4, line: i + 2) })
    let cs = Stats.compute(careful)
    check(cs.reliable, "the same walk with 4 m error is measurable")
    near(cs.averageSpeedMS, 1.4, 0.25, "and its average is about 1.4 m/s (5 km/h): \(cs.averageSpeedMS)")
}
do { // Detector.trustedIndices: one definition of a bad fix, shared by the verdict and the statistics
    let clean = runTrace(100, metersPerSecond: 10).fixes
    check(Detector.trustedIndices(clean) == Array(clean.indices), "an honest trace trusts every fix")
    var one = clean; one[50].point = Geo.destination(one[50].point, bearing: 90, meters: 600)
    check(Detector.trustedIndices(one) == clean.indices.filter { $0 != 50 }, "a lone bad fix is the only one dropped")
    var zig = runTrace(300, metersPerSecond: 10).fixes
    for k in stride(from: 20, to: 280, by: 2) { zig[k].point = Geo.destination(zig[k].point, bearing: 90, meters: 600) }
    check(Detector.trustedIndices(zig).count == zig.count, "a zig-zag of 130 bad fixes is tampering, not glitches: none are dropped")
    check(Detector.trustedIndices([]) == [] && Detector.trustedIndices([clean[0]]) == [0], "empty and one-fix inputs are fine")
}
do { // reported accuracy is forgiven, as in the detector, so a stationary noisy receiver is not "moving"
    let still = Trace(fixes: (0..<50).map { i in
        Fix(point: GeoPoint(lat: 10 + (i % 2 == 0 ? 0.00003 : -0.00003), lon: 20), time: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), accuracyM: 20, line: i + 2)
    })
    check(Stats.compute(still).topSpeedMS == 0, "jitter inside the reported accuracy is not speed: \(Stats.compute(still).topSpeedMS)")
}
do { // degenerate inputs never crash and never produce non-finite headline numbers
    for t in [Trace(fixes: []), Trace(fixes: [fix(1, 1)]), Trace(fixes: [fix(1, 1, 0), fix(1, 1, 0)]), Trace(fixes: [fix(1, 1, 5), fix(2, 2, 5)]),
              Trace(fixes: Array(repeating: fix(5, 5), count: 30))] {
        let s = Stats.compute(t)
        check(s.distanceM.isFinite && s.averageSpeedMS.isFinite && s.topSpeedMS.isFinite && s.duration.isFinite && s.duration >= 0,
              "finite headline numbers for \(t.fixes.count) fix(es)")
    }
    check(Stats.compute(Trace(fixes: [])).isEmpty && Stats.compute(Trace(fixes: [fix(1, 1)])).isEmpty, "0 or 1 fix is flagged as empty")
    check(Stats.compute(Trace(fixes: [fix(1, 1, 0), fix(1.0001, 1, 1)])).isEmpty == false, "2 fixes is enough")
}
do { // out-of-order input is analysed in time order
    var fixes = runTrace(11, metersPerSecond: 10).fixes
    fixes.reverse()
    near(Stats.compute(Trace(fixes: fixes)).distanceM, 100, 0.5, "shuffled input gives the same distance")
}
do { // percentile
    near(Stats.percentile([1, 2, 3, 4, 5], 0.5), 3, 1e-12, "median")
    near(Stats.percentile([1, 2, 3, 4, 5], 0), 1, 1e-12, "p0 is the minimum")
    near(Stats.percentile([1, 2, 3, 4, 5], 1), 5, 1e-12, "p100 is the maximum")
    near(Stats.percentile([10, 20], 0.5), 15, 1e-12, "interpolates between values")
    check(Stats.percentile([], 0.5) == 0, "no values gives 0")
    near(Stats.percentile([7], 0.99), 7, 1e-12, "one value")
    near(Stats.percentile([1, .nan, 3, .infinity], 0.5), 2, 1e-12, "non-finite values are ignored")
    check(Stats.percentile([1, 2, 3], -5) == 1 && Stats.percentile([1, 2, 3], 5) == 3, "p is clamped to 0...1")
}
do { // formatting
    check(Stats.distanceText(0) == "0 m" && Stats.distanceText(999) == "999 m", "metres")
    check(Stats.distanceText(1500) == "1.5 km" && Stats.distanceText(99_999) == "100.0 km", "kilometres with a decimal")
    check(Stats.distanceText(250_000) == "250 km", "large distances drop the decimal")
    check(Stats.durationText(0) == "0 s" && Stats.durationText(59) == "59 s", "seconds")
    check(Stats.durationText(60) == "1 min 0 s" && Stats.durationText(125) == "2 min 5 s", "minutes")
    check(Stats.durationText(3600) == "1 h 0 min" && Stats.durationText(7500) == "2 h 5 min", "hours")
    check(Stats.speedText(10) == "36 km/h", "10 m/s is 36 km/h: \(Stats.speedText(10))")
}

// ---------------- SpeedRamp ----------------
do {
    let lums = SpeedRamp.steps.map { SpeedRamp.luminance($0) }
    check(zip(lums, lums.dropFirst()).allSatisfy { $0 > $1 }, "ramp gets strictly darker with speed: \(lums.map { String(format: "%.3f", $0) })")
    check(lums[0] > 0.65 && lums[0] < 0.85, "the slowest step is visible on white (luminance \(lums[0]))")
    let hues = SpeedRamp.steps.map { c in c.b > c.r && c.b > c.g * 0.99 }
    check(hues.allSatisfy { $0 }, "every step is blue-dominant: one hue family")
    let c0 = SpeedRamp.colour(speed: 0, top: 30), c1 = SpeedRamp.colour(speed: 30, top: 30), cx = SpeedRamp.colour(speed: 900, top: 30)
    check(c0.r == SpeedRamp.steps[0].r, "zero speed is the slowest colour")
    check(c1.r == SpeedRamp.steps.last!.r && cx.r == c1.r, "top speed and anything above are the fastest colour")
    for bad in [Double.nan, -3, .infinity] { check(SpeedRamp.colour(speed: bad, top: 30).r == SpeedRamp.steps[0].r, "bad speed \(bad) falls back to the slowest") }
    for top in [0.0, -1, .nan, .infinity] { check(SpeedRamp.colour(speed: 5, top: top).r == SpeedRamp.steps[0].r, "bad top \(top) falls back, no crash") }
    var prev = 2.0, mono = true
    for k in 0...60 { let l = SpeedRamp.luminance(SpeedRamp.colour(speed: Double(k), top: 60)); if l > prev + 1e-12 { mono = false }; prev = l }
    check(mono, "interpolated colour never gets lighter as speed rises")
}

// ---------------- replayStep (the replay clock) ----------------
do {
    // a replay always takes between 6 and 40 seconds to watch, whatever the trip length
    func secondsToWatch(_ tripSeconds: Double) -> Double {
        var f = 0.0, t = 0.0
        while f < 1 && t < 1000 { f = replayStep(fraction: f, durationSeconds: tripSeconds, dt: 1.0 / 30.0); t += 1.0 / 30.0 }
        return t
    }
    near(secondsToWatch(2), 6, 0.1, "a 2-second trip is slowed to a watchable 6 s: \(secondsToWatch(2))")
    near(secondsToWatch(20), 20, 0.1, "a 20-second trip replays in real time: \(secondsToWatch(20))")
    near(secondsToWatch(36_000), 40, 0.1, "a 10-hour trip is sped up to 40 s: \(secondsToWatch(36_000))")
    check(replayStep(fraction: 0.5, durationSeconds: 100, dt: 1.0 / 30.0) > 0.5, "it moves forward")
    check(replayStep(fraction: 0.999, durationSeconds: 20, dt: 5) == 1, "it never goes past the end")
    check(replayStep(fraction: -2, durationSeconds: 20, dt: 0.1) >= 0, "a negative start is clamped")
    for bad in [(Double.nan, 20.0, 0.1), (0.5, .nan, 0.1), (0.5, 20, .nan), (0.5, 0, 0.1), (0.5, -5, 0.1), (0.5, 20, 0), (0.5, 20, -1), (.infinity, 20, 0.1)] {
        let r = replayStep(fraction: bad.0, durationSeconds: bad.1, dt: bad.2)
        check(r.isFinite && r >= 0 && r <= 1, "bad input \(bad) gives a valid fraction (\(r)), never NaN or out of range")
    }
}
do { // the statistics are computed once and stored, so the views never recompute them on a redraw
    let a = Analysis(fileName: "t", trace: runTrace(101, metersPerSecond: 10), findings: [], verdict: .clean)
    near(a.stats.distanceM, 1000, 1.0, "Analysis stores the trip distance")
    near(a.duration, 100, 1e-9, "Analysis stores the duration")
    check(a.stats.fixCount == 101, "and the fix count")
    let b = Analysis(fileName: "t", trace: runTrace(101, metersPerSecond: 10), findings: [], verdict: .clean)
    check(a == b, "two analyses of the same trace are equal")
}

// ---------------- replayPosition ----------------
do {
    let f = runTrace(11, metersPerSecond: 10).fixes     // t = 0...10 s
    check(replayPosition(f, fraction: 0)?.index == 0 && replayPosition(f, fraction: 0)?.along == 0, "start of replay is the first fix")
    let end = replayPosition(f, fraction: 1)
    check(end?.index == 10 && end?.along == 0, "end of replay is the last fix: \(String(describing: end))")
    let mid = replayPosition(f, fraction: 0.25)!           // 2.5 s: halfway between fix 2 and 3
    check(mid.index == 2 && abs(mid.along - 0.5) < 1e-9, "a quarter of the way is halfway between fixes 2 and 3: \(mid)")
    check(replayPosition(f, fraction: -3)?.index == 0 && replayPosition(f, fraction: 9)?.index == 10, "out-of-range fractions are clamped")
    check(replayPosition(f, fraction: .nan) != nil, "NaN fraction does not crash")
    check(replayPosition([], fraction: 0.5) == nil, "no fixes, no position")
    check(replayPosition([fix(1, 1)], fraction: 0.5)?.index == 0, "a single fix replays at that fix")
    check(replayPosition([fix(1, 1, 5), fix(2, 2, 5)], fraction: 0.5)?.index == 0, "no elapsed time: stays at the start")
    // every fraction maps to a valid segment
    var ok = true
    for k in 0...200 { if let p = replayPosition(f, fraction: Double(k) / 200) { if p.index < 0 || p.index >= f.count || p.along < 0 || p.along > 1 { ok = false } } else { ok = false } }
    check(ok, "every fraction 0...1 maps to a valid index and offset")
    // uneven spacing: the marker follows TIME, so it lingers where the device did
    let uneven = [fix(0, 0, 0), fix(0, 0.001, 1), fix(0, 0.002, 91)]
    let p = replayPosition(uneven, fraction: 0.5)!         // 45.5 s is in the long second gap
    check(p.index == 1 && p.along > 0.4 && p.along < 0.6, "the marker follows elapsed time, not fix count: \(p)")
}

print(failures == 0 ? "all \(total) checks passed" : "\(failures) of \(total) check(s) FAILED")
exit(failures == 0 ? 0 : 1)
