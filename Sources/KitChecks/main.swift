import Foundation
import GeoSentinelKit

// A small self-contained test runner: the standard Swift test frameworks need a full Xcode install,
// which this project is built without. Exits non-zero if any check fails.
var failures = 0, total = 0
func check(_ ok: Bool, _ msg: String, file: StaticString = #fileID, line: UInt = #line) {
    total += 1
    if !ok { failures += 1; print("FAIL: \(msg)  (\(file):\(line))") }
}
func near(_ a: Double, _ b: Double, _ tol: Double, _ msg: String, line: UInt = #line) {
    check(abs(a - b) <= tol, "\(msg): got \(a), want \(b) +/- \(tol)", line: line)
}

// ---------------- geometry (same reference values as the Go tests) ----------------
let london = GeoPoint(lat: 51.5074, lon: -0.1278), paris = GeoPoint(lat: 48.8566, lon: 2.3522)
near(Geo.distance(london, paris), 343_500, 1500, "London-Paris")
near(Geo.distance(GeoPoint(lat: 40.7128, lon: -74.0060), GeoPoint(lat: 34.0522, lon: -118.2437)), 3_936_000, 15_000, "NYC-LA")
near(Geo.distance(GeoPoint(lat: 0, lon: 0), GeoPoint(lat: 1, lon: 0)), 111_195, 150, "1 degree of latitude")
check(Geo.distance(london, london) == 0, "distance to self")
check(!Geo.distance(GeoPoint(lat: 0, lon: 0), GeoPoint(lat: 0, lon: 180)).isNaN, "antipodal is not NaN")
check(Geo.distance(GeoPoint(lat: 0, lon: 179.9999), GeoPoint(lat: 0, lon: -179.9999)) < 30, "antimeridian crossing is short")
near(Geo.bearing(GeoPoint(lat: 0, lon: 0), GeoPoint(lat: 1, lon: 0)), 0, 0.01, "bearing north")
near(Geo.bearing(GeoPoint(lat: 0, lon: 0), GeoPoint(lat: 0, lon: 1)), 90, 0.01, "bearing east")
near(Geo.angleDiff(10, 350), 20, 1e-9, "angle diff wraps")
for br in stride(from: 0.0, to: 360, by: 45) {
    for d in [1.0, 100, 5000, 250_000] {
        let end = Geo.destination(GeoPoint(lat: 47.6, lon: -122.3), bearing: br, meters: d)
        near(Geo.distance(GeoPoint(lat: 47.6, lon: -122.3), end), d, d * 1e-6 + 1e-6, "destination round trip \(br)/\(d)")
    }
}
check(!GeoPoint(lat: 91, lon: 0).isValid && !GeoPoint(lat: .nan, lon: 0).isValid && GeoPoint(lat: 90, lon: 180).isValid, "validity")

// ---------------- CSV parser ----------------
func csv(_ s: String) throws -> Trace { try CSVParser.parse(Data(s.utf8)) }
func parseError(_ s: String) -> ParseError? { do { _ = try csv(s); return nil } catch { return error as? ParseError } }

if let t = try? csv("time,lat,lon,accuracy\n2026-11-12T10:00:00Z,47.6,-122.3,5\n2026-11-12T10:00:10Z,47.6001,-122.3001,6.5\n") {
    check(t.fixes.count == 2, "two fixes")
    check(t.fixes[1].line == 3 && t.fixes[1].accuracyM == 6.5, "second fix line and accuracy")
} else { check(false, "good CSV should parse") }
if let t = try? csv("\u{FEFF}LON, Lat ,TIME,extra\n-122.3,47.6,1700000000,zzz\n") {
    check(t.fixes[0].point.lat == 47.6 && t.fixes[0].accuracyM == nil, "column order, case, BOM")
} else { check(false, "BOM/order CSV should parse") }

let bad: [(String, String, Int)] = [
    ("", "empty file", 1), ("time,lat,lon\n", "no data rows", 0), ("time,lat\n1,2\n", "missing required column \"lon\"", 1),
    ("time,lat,lat,lon\n", "duplicate column", 1), ("time,lat,lon\n1700000000,1\n", "row has 2 columns", 2),
    ("time,lat,lon\n1700000000,north,2\n", "bad lat", 2), ("time,lat,lon\n1700000000,NaN,2\n", "not finite", 2),
    ("time,lat,lon\n1700000000,1,Inf\n", "not finite", 2), ("time,lat,lon\n1700000000,0x1p3,2\n", "plain decimal", 2),
    ("time,lat,lon\nyesterday,1,2\n", "neither RFC 3339 nor Unix", 2), ("time,lat,lon\n-5,1,2\n", "outside 1970-2100", 2),
    ("time,lat,lon\n9e18,1,2\n", "outside 1970-2100", 2), ("time,lat,lon,accuracy\n1700000000,1,2,wide\n", "bad accuracy", 2),
    ("time,lat,lon\n1700000000,\"1\",2\n", "quoted fields", 2),
]
for (input, want, line) in bad {
    if let e = parseError(input) { check(e.message.contains(want) && e.line == line, "error for \(input.debugDescription): got \(e), want '\(want)' line \(line)") }
    else { check(false, "should have rejected \(input.debugDescription)") }
}
check((try? CSVParser.parse(Data([0xff, 0xfe, 0x00, 0x80]))) == nil, "invalid UTF-8 is rejected, not crashed on")

// ---------------- detection on the SAME example files as the Go tool ----------------
func load(_ name: String) -> Trace {
    let url = URL(fileURLWithPath: "TestData/\(name).csv")
    guard let d = try? Data(contentsOf: url), let t = try? CSVParser.parse(d) else { print("FAIL: cannot load \(name)"); failures += 1; return Trace(fixes: []) }
    return t
}
let expected: [(String, Verdict)] = [
    ("honest_drive", .clean), ("honest_walk", .clean), ("fake_teleport", .likelySpoofed),
    ("fake_frozen", .suspicious), ("fake_scripted", .suspicious), ("fake_careful", .clean),   // careful fake: the documented blind spot
]
for (name, want) in expected {
    let findings = Detector.analyze(load(name))
    let got = Detector.judge(findings)
    check(got == want, "\(name): verdict \(got.rawValue), want \(want.rawValue)")
}

// ---------------- live recording: fixes have no source line (line == 0) ----------------
// The phone app builds fixes as they arrive, so every line is 0. Findings must still be reported and
// the de-duplication must not mix unrelated events together just because they share "line 0".
func zeroLines(_ t: Trace) -> Trace { Trace(fixes: t.fixes.map { var f = $0; f.line = 0; return f }) }
do {
    let live = zeroLines(load("fake_teleport"))
    let fs = Detector.analyze(live)
    check(Detector.judge(fs) == .likelySpoofed, "live teleport still judged likely-spoofed with line == 0")
    check(fs.contains { $0.check == "speed" } && fs.contains { $0.check == "teleport" }, "live teleport reports speed and teleport")
    // The acceleration findings that restate the jump should be folded away, as they are for files.
    let fromFile = Detector.analyze(load("fake_teleport"))
    check(fs.count == fromFile.count, "same number of findings live (\(fs.count)) as from the file (\(fromFile.count))")
    for name in ["honest_drive", "honest_walk", "fake_frozen", "fake_scripted", "fake_careful"] {
        let a = Detector.judge(Detector.analyze(load(name))), b = Detector.judge(Detector.analyze(zeroLines(load(name))))
        check(a == b, "\(name): verdict differs with line == 0 (\(a.rawValue) vs \(b.rawValue))")
    }
}

// ---------------- one GPS glitch in an honest trace must not make it "suspicious" ----------------
// A single bad fix that corrects itself is what a receiver glitch looks like. It must never change the verdict
// by itself (whatever its size up to the ceiling), and must never be reported as an acceleration.
do {
    let base = load("honest_drive")
    for meters in [150.0, 300.0, 800.0, 5000.0] {
        var fixes = base.fixes
        fixes[150].point = Geo.destination(fixes[150].point, bearing: 90, meters: meters)
        let fs = Detector.analyze(Trace(fixes: fixes))
        check(Detector.judge(fs) == .clean, "a single \(Int(meters)) m glitch: verdict \(Detector.judge(fs).rawValue), findings \(fs.map { $0.check })")
        check(!fs.contains { $0.check == "acceleration" }, "glitch of \(Int(meters)) m must not also be an acceleration")
    }
}

// ---------------- the outlier handling must not hide real anomalies ----------------
do {
    let base = load("honest_drive")
    func verdict(_ mutate: (inout [Fix]) -> Void) -> Verdict { var f = base.fixes; mutate(&f); return Detector.judge(Detector.analyze(Trace(fixes: f))) }
    // a zig-zag: every second fix displaced 600 m. Each looks like an isolated outlier alone; together they are tampering.
    let zig = verdict { f in for i in stride(from: 20, to: 280, by: 2) { f[i].point = Geo.destination(f[i].point, bearing: 90, meters: 600) } }
    check(zig != .clean, "a zig-zag of 130 displaced fixes was judged clean")
    // a two-fix excursion is not an isolated outlier
    let two = verdict { f in for i in [150, 151] { f[i].point = Geo.destination(f[i].point, bearing: 90, meters: 5000) } }
    check(two != .clean, "a two-fix 5 km excursion was judged clean")
    // many repeated lone outliers escalate
    let many = verdict { f in for i in stride(from: 20, to: 280, by: 10) { f[i].point = Geo.destination(f[i].point, bearing: 90, meters: 400_000) } }
    check(many == .likelySpoofed, "26 repeated lone outliers: \(many.rawValue)")
}

// ---------------- LiveRecorder ----------------
do {
    let r = LiveRecorder(capacity: 5)
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    check(r.assess() == nil, "no verdict with no fixes")
    check(r.add(lat: 47.6, lon: -122.3, accuracyM: 5, time: t0), "valid fix accepted")
    check(r.assess() == nil, "no verdict with one fix")
    check(!r.add(lat: 95, lon: 0, accuracyM: 5, time: t0), "out-of-range latitude rejected")
    check(!r.add(lat: .nan, lon: 0, accuracyM: 5, time: t0), "NaN rejected")
    check(!r.add(lat: 47.6, lon: -122.3, accuracyM: -1, time: t0), "negative accuracy (CoreLocation's 'invalid') rejected")
    check(!r.add(lat: 47.6, lon: -122.3, accuracyM: .infinity, time: t0), "infinite accuracy rejected")
    check(r.add(lat: 47.6, lon: -122.3, accuracyM: nil, time: t0.addingTimeInterval(1)), "unknown accuracy is allowed")
    check(r.rejected == 4 && r.fixes.count == 2, "rejected=\(r.rejected) fixes=\(r.fixes.count)")
    for i in 2..<12 { r.add(lat: 47.6 + Double(i) * 1e-5, lon: -122.3, accuracyM: 5, time: t0.addingTimeInterval(Double(i))) }
    check(r.fixes.count == 5, "capacity is enforced: \(r.fixes.count)")
    check(r.fixes.last?.time == t0.addingTimeInterval(11), "the NEWEST fixes are the ones kept")
    r.reset()
    check(r.fixes.isEmpty && r.rejected == 0, "reset clears everything")

    // End to end: feeding the recorder a teleport, fix by fix, as a phone would, is caught.
    let live = LiveRecorder()
    for (i, f) in load("fake_teleport").fixes.enumerated() {
        live.add(lat: f.point.lat, lon: f.point.lon, accuracyM: f.accuracyM, time: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
    }
    check(live.assess()?.verdict == .likelySpoofed, "live-fed teleport is judged likely-spoofed")
    let honest = LiveRecorder()
    for (i, f) in load("honest_drive").fixes.enumerated() {
        honest.add(lat: f.point.lat, lon: f.point.lon, accuracyM: f.accuracyM, time: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
    }
    check(honest.assess()?.verdict == .clean, "live-fed honest drive is judged clean")
}

// ---------------- GPX parser ----------------
func gpx(_ s: String) throws -> Trace { try GPXParser.parse(Data(s.utf8)) }
func gpxError(_ s: String) -> ParseError? { do { _ = try gpx(s); return nil } catch { return error as? ParseError } }

let goodGPX = """
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="t" xmlns="http://www.topografix.com/GPX/1/1">
 <wpt lat="1" lon="1"><time>2026-11-12T09:00:00Z</time></wpt>
 <trk><trkseg>
  <trkpt lat="47.6000" lon="-122.3000"><ele>10</ele><time>2026-11-12T10:00:00Z</time><hdop>1.2</hdop></trkpt>
  <trkpt lat="47.6001" lon="-122.3001"><time>2026-11-12T10:00:10Z</time><accuracy>3.5</accuracy></trkpt>
 </trkseg></trk>
</gpx>
"""
if let t = try? gpx(goodGPX) {
    check(t.fixes.count == 2, "GPX: waypoints ignored, 2 trackpoints (got \(t.fixes.count))")
    check(t.fixes[0].accuracyM == 6, "GPX: hdop 1.2 -> 6 m (got \(String(describing: t.fixes[0].accuracyM)))")
    check(t.fixes[1].accuracyM == 3.5, "GPX: explicit accuracy")
} else { check(false, "good GPX should parse") }

let badGPX: [(String, String, String)] = [
    ("not xml", "hello", "invalid XML"),
    ("wrong root", "<kml><trkpt lat=\"1\" lon=\"1\"/></kml>", "not a GPX file"),
    ("no trackpoints", "<gpx><wpt lat=\"1\" lon=\"1\"/></gpx>", "no <trkpt>"),
    ("missing lon", "<gpx><trkpt lat=\"1\"><time>2026-11-12T10:00:00Z</time></trkpt></gpx>", "needs lat and lon"),
    ("bad lat", "<gpx><trkpt lat=\"abc\" lon=\"1\"><time>2026-11-12T10:00:00Z</time></trkpt></gpx>", "bad lat"),
    ("bad time", "<gpx><trkpt lat=\"1\" lon=\"1\"><time>never</time></trkpt></gpx>", "bad time"),
    ("no time", "<gpx><trkpt lat=\"1\" lon=\"1\"></trkpt></gpx>", "no <time>"),
    ("truncated", "<gpx><trk><trkseg><trkpt lat=\"1\" lon=\"1\"><time>2026-11-12T10:00:00Z</time>", "invalid XML"),
    ("NaN lat", "<gpx><trkpt lat=\"NaN\" lon=\"1\"><time>2026-11-12T10:00:00Z</time></trkpt></gpx>", "not finite"),
]
for (name, input, want) in badGPX {
    if let e = gpxError(input) { check(e.message.contains(want), "GPX \(name): got '\(e.message)', want '\(want)'") }
    else { check(false, "GPX \(name) should be rejected") }
}

// hostile documents
let bomb = """
<?xml version="1.0"?>
<!DOCTYPE gpx [ <!ENTITY a "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa">
 <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"> <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;"> <!ENTITY d "&c;&c;&c;&c;&c;&c;&c;&c;&c;&c;"> ]>
<gpx><trk><trkseg><trkpt lat="1" lon="1"><time>&d;</time></trkpt></trkseg></trk></gpx>
"""
let started = Date()
check(gpxError(bomb)?.message.contains("DOCTYPE") == true, "entity bomb is refused up front")
check(Date().timeIntervalSince(started) < 2, "entity bomb is rejected quickly, not expanded")
let xxe = "<?xml version=\"1.0\"?><!DOCTYPE gpx [ <!ENTITY x SYSTEM \"file:///etc/passwd\"> ]><gpx><trkpt lat=\"1\" lon=\"1\"><time>&x;</time></trkpt></gpx>"
let xxeErr = gpxError(xxe)
check(xxeErr != nil && !xxeErr!.message.contains("root:"), "external entity refused and nothing leaked: \(String(describing: xxeErr))")
check(gpxError("<!DocType gpx []><gpx><trkpt lat=\"1\" lon=\"1\"/></gpx>")?.message.contains("DOCTYPE") == true, "mixed-case DOCTYPE is still caught")

// depth and text limits use input that is otherwise valid, so the limit is the ONLY thing that can reject it
let deep = "<gpx>" + String(repeating: "<x>", count: 100) + "<trkpt lat=\"1\" lon=\"1\"><time>2026-11-12T10:00:00Z</time></trkpt>" + String(repeating: "</x>", count: 100) + "</gpx>"
check(gpxError(deep)?.message.contains("nested too deeply") == true, "100-deep nesting refused: \(String(describing: gpxError(deep)))")
let shallow = "<gpx>" + String(repeating: "<x>", count: 10) + "<trkpt lat=\"1\" lon=\"1\"><time>2026-11-12T10:00:00Z</time></trkpt>" + String(repeating: "</x>", count: 10) + "</gpx>"
check(gpxError(shallow) == nil, "10-deep nesting is fine")
let padded = "<gpx><trkpt lat=\"1\" lon=\"1\"><time>2026-11-12T10:00:00Z" + String(repeating: " ", count: 1000) + "</time></trkpt></gpx>"
check(gpxError(padded)?.message.contains("unreasonably long") == true, "1000-byte element text refused: \(String(describing: gpxError(padded)))")
check(gpxError("<gpx><trkpt lat=\"1\" lon=\"1\"><time>2026-11-12T10:00:00Z   </time></trkpt></gpx>") == nil, "short padded text is fine")
check((try? GPXParser.parse(Data([0xff, 0xfe, 0x00, 0x80]))) == nil, "binary garbage is rejected, not crashed on")

print(failures == 0 ? "all \(total) checks passed" : "\(failures) of \(total) check(s) FAILED")
exit(failures == 0 ? 0 : 1)
