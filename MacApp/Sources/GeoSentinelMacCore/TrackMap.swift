import SwiftUI
import GeoSentinelKit

/// Maps a trace onto a rectangle. Pure geometry, no drawing, so the awkward cases can be tested exactly.
public struct MapProjection: Equatable {
    public var minLat: Double, maxLat: Double, minLon: Double, maxLon: Double

    /// A view box around the trace: padded, never degenerate, and clamped to the world.
    /// If the trace crosses the antimeridian, longitudes are unwrapped so it is one continuous span.
    public init(fixes: [Fix], aspect: Double) {
        let lats = fixes.map { $0.point.lat }
        var lons = fixes.map { $0.point.lon }
        if let lo = lons.min(), let hi = lons.max(), hi - lo > 180 {            // crosses the date line
            lons = lons.map { $0 < 0 ? $0 + 360 : $0 }
        }
        var la0 = lats.min() ?? 0, la1 = lats.max() ?? 0
        var lo0 = lons.min() ?? 0, lo1 = lons.max() ?? 0
        // Degrees of longitude shrink with latitude; compare spans in comparable (ground) units.
        let midLat = (la0 + la1) / 2
        let cosMid = max(0.05, cos(midLat * .pi / 180))
        let minSpan = 0.0005                                                        // ~50 m: a single point still gets a map
        var latSpan = max(la1 - la0, minSpan)
        var lonSpan = max((lo1 - lo0) * cosMid, minSpan)
        // pad 12%
        latSpan *= 1.24; lonSpan *= 1.24
        // Grow one axis so the box has the requested aspect ratio (width / height) without distorting shape.
        // Exception: a trace spanning continents (wider than the globe allows at this aspect) would need a box
        // taller than the planet, so there the latitude range is held to a sensible size and shapes are allowed to
        // stretch horizontally. Nothing here has coastlines to compare shapes against, so labels matter more.
        if lonSpan / latSpan < aspect {
            lonSpan = latSpan * aspect
        } else {
            let wanted = lonSpan / aspect
            latSpan = min(wanted, max(latSpan, 60))   // at most 60 degrees tall unless the data itself is taller
        }
        let cLat = (la0 + la1) / 2, cLon = (lo0 + lo1) / 2
        // The box is centred on the data. Near a pole it would hang off the end of the globe; shifting it back on
        // would leave the data jammed against the edge of an otherwise empty map (a real bug: a walk at 89.95 N
        // ran along the very top of the picture). The data matters more than the aspect ratio, so if the box
        // would pass a pole, shrink it symmetrically so it stays centred and stays on the globe.
        let room = 90 - abs(cLat)                        // degrees between the data's centre and the nearer pole
        let half = min(latSpan / 2, max(room, minSpan))  // never collapse to nothing
        la0 = cLat - half; la1 = cLat + half
        lo0 = cLon - lonSpan / cosMid / 2; lo1 = cLon + lonSpan / cosMid / 2
        minLat = la0; maxLat = la1; minLon = lo0; maxLon = lo1
    }

    /// Position in a width x height rectangle (origin top-left). Longitudes below the box's range are
    /// shifted by 360 so a date-line trace lands inside it.
    public func point(_ p: GeoPoint, width: Double, height: Double) -> CGPoint {
        var lon = p.lon
        if maxLon > 180 && lon < 0 { lon += 360 }
        let x = (lon - minLon) / max(1e-12, maxLon - minLon) * width
        let y = (maxLat - p.lat) / max(1e-12, maxLat - minLat) * height
        return CGPoint(x: x, y: y)
    }
}

/// Splits a polyline wherever consecutive points jump so far apart on screen that connecting them would draw
/// a line across the map. Real fast motion is continuous, so this only breaks genuine teleports and
/// date-line wraps, and leaves a visible gap where the jump is. Also returns where the breaks fall.
public func trackSegments(_ pts: [CGPoint], breakDistance: Double) -> [[CGPoint]] {
    var out: [[CGPoint]] = [], cur: [CGPoint] = []
    for p in pts {
        if let l = cur.last, hypot(p.x - l.x, p.y - l.y) > breakDistance { out.append(cur); cur = [] }
        cur.append(p)
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}

public struct TrackMap: View {
    let analysis: Analysis
    /// Index (into the SORTED trace) of the finding the user picked, drawn with a marker.
    var highlight: Int?
    /// Replay position as a fraction 0...1 of elapsed time, or nil for no replay marker. The marker rides the
    /// RECORDED positions (interpolated between two real fixes) and never shows a place that is not in the file.
    var replay: Double?
    /// Colour the path by step speed (darker = faster). Off draws a plain accent line.
    var colourBySpeed: Bool

    public init(analysis: Analysis, highlight: Int? = nil, replay: Double? = nil, colourBySpeed: Bool = true) {
        self.analysis = analysis; self.highlight = highlight; self.replay = replay; self.colourBySpeed = colourBySpeed
    }

    private var fixes: [Fix] { analysis.trace.sortedByTime().trace.fixes }

    public var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .textBackgroundColor)))
            let f = fixes
            guard !f.isEmpty else { return }
            let proj = MapProjection(fixes: f, aspect: Double(size.width / max(1, size.height)))

            // graticule: a few evenly spaced lat/lon lines, labelled sparingly
            let grid = Color.secondary.opacity(0.25)
            for i in 0...4 {
                let y = size.height * Double(i) / 4, x = size.width * Double(i) / 4
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) }, with: .color(grid), lineWidth: 1)
                ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(grid), lineWidth: 1)
            }
            ctx.draw(Text(String(format: "%.4f°", proj.maxLat)).font(.system(size: 10)).foregroundColor(.secondary),
                     at: CGPoint(x: 4, y: 3), anchor: .topLeading)
            ctx.draw(Text(String(format: "%.4f°", proj.minLat)).font(.system(size: 10)).foregroundColor(.secondary),
                     at: CGPoint(x: 4, y: size.height - 3), anchor: .bottomLeading)

            let pts = f.map { proj.point($0.point, width: size.width, height: size.height) }
            let flagged = Set(analysis.findings.compactMap { $0.fixIndex >= 0 ? $0.fixIndex : nil })

            // the path, broken where it jumps; the jumps themselves are drawn dashed so the story stays visible
            let segs = trackSegments(pts, breakDistance: Double(min(size.width, size.height)) * 0.5)
            // Speed colouring shows the same numbers the stat tiles do, so when those cannot be trusted the path is
            // drawn plain. (On a walk with ~13 m of GPS error the few windows that cleared the noise floor were drawn
            // dark blue among light ones, suggesting bursts of speed that were never there.)
            if colourBySpeed && analysis.stats.reliable {
                // One short stroke per step, coloured by that step's speed on a single-hue ramp (darker = faster).
                // Steps that are jumps (NaN) are skipped here and drawn dashed below.
                let stats = analysis.stats
                let top = max(stats.topSpeedMS, 1)
                for i in 1..<max(1, pts.count) where i < stats.stepSpeeds.count {
                    let a = pts[i - 1], b = pts[i]
                    if hypot(b.x - a.x, b.y - a.y) > Double(min(size.width, size.height)) * 0.5 { continue }
                    let c = SpeedRamp.colour(speed: stats.stepSpeeds[i], top: top)
                    ctx.stroke(Path { p in p.move(to: a); p.addLine(to: b) },
                               with: .color(Color(red: c.r, green: c.g, blue: c.b)),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            } else {
                for seg in segs where seg.count > 1 {
                    ctx.stroke(Path { p in p.move(to: seg[0]); seg.dropFirst().forEach { p.addLine(to: $0) } },
                               with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            for k in 1..<max(1, segs.count) {
                if let a = segs[k - 1].last, let b = segs[k].first {
                    ctx.stroke(Path { p in p.move(to: a); p.addLine(to: b) }, with: .color(.red),
                               style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                }
            }
            // flagged fixes: a diamond with an outline (shape differs from the dots above), plus the picked one larger
            for i in flagged.sorted() where i < pts.count {
                let p = pts[i]
                var d = Path(); d.move(to: CGPoint(x: p.x, y: p.y - 7)); d.addLine(to: CGPoint(x: p.x + 7, y: p.y))
                d.addLine(to: CGPoint(x: p.x, y: p.y + 7)); d.addLine(to: CGPoint(x: p.x - 7, y: p.y)); d.closeSubpath()
                ctx.fill(d, with: .color(.red)); ctx.stroke(d, with: .color(.white), lineWidth: 1.5)
            }
            // start and end: shape AND label, never colour alone
            ctx.fill(Path(ellipseIn: CGRect(x: pts[0].x - 5, y: pts[0].y - 5, width: 10, height: 10)), with: .color(.green))
            // labels get a halo (the same text drawn thicker in the map's own background colour first) so they stay
            // readable where the path runs underneath them
            let halo = Color(nsColor: .textBackgroundColor)
            for (dx, dy) in [(-1.5, 0.0), (1.5, 0.0), (0.0, -1.5), (0.0, 1.5), (-1.1, -1.1), (1.1, 1.1), (-1.1, 1.1), (1.1, -1.1)] {
                ctx.draw(Text("start").font(.system(size: 10, weight: .semibold)).foregroundColor(halo),
                         at: CGPoint(x: pts[0].x + 9 + dx, y: pts[0].y - 9 + dy), anchor: .bottomLeading)
            }
            ctx.draw(Text("start").font(.system(size: 10, weight: .semibold)), at: CGPoint(x: pts[0].x + 9, y: pts[0].y - 9), anchor: .bottomLeading)
            if let e = pts.last, pts.count > 1 {
                ctx.fill(Path(CGRect(x: e.x - 5, y: e.y - 5, width: 10, height: 10)), with: .color(.primary))
                for (dx, dy) in [(-1.5, 0.0), (1.5, 0.0), (0.0, -1.5), (0.0, 1.5), (-1.1, -1.1), (1.1, 1.1), (-1.1, 1.1), (1.1, -1.1)] {
                    ctx.draw(Text("end").font(.system(size: 10, weight: .semibold)).foregroundColor(halo),
                             at: CGPoint(x: e.x + 9 + dx, y: e.y + 9 + dy), anchor: .topLeading)
                }
                ctx.draw(Text("end").font(.system(size: 10, weight: .semibold)), at: CGPoint(x: e.x + 9, y: e.y + 9), anchor: .topLeading)
            }
            if let h = highlight, h >= 0, h < pts.count {
                let p = pts[h]
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26)), with: .color(.red), lineWidth: 2.5)
            }
            // replay marker: a ring with a dot, riding the recorded positions between two real fixes
            if let r = replay, let pos = replayPosition(f, fraction: r), pos.index < pts.count {
                let a = pts[pos.index]
                let b = pos.index + 1 < pts.count ? pts[pos.index + 1] : a
                // never draw a marker sliding across a jump: if the two fixes are a jump apart, stay on the first
                let jump = hypot(b.x - a.x, b.y - a.y) > Double(min(size.width, size.height)) * 0.5
                let p = jump ? a : CGPoint(x: a.x + (b.x - a.x) * pos.along, y: a.y + (b.y - a.y) * pos.along)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)), with: .color(.white))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)), with: .color(.accentColor), lineWidth: 3)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.accentColor))
            }
        }
        .accessibilityLabel("Map of the recorded path with \(analysis.findings.count) flagged point\(analysis.findings.count == 1 ? "" : "s")")
    }
}
