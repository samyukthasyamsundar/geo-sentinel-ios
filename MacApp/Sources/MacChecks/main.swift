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

print(failures == 0 ? "all \(total) checks passed" : "\(failures) of \(total) check(s) FAILED")
exit(failures == 0 ? 0 : 1)
