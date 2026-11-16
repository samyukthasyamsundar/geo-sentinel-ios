import Foundation

/// Reads trackpoints (`<trkpt>`) from a GPX document, across all tracks and segments. Waypoints and
/// routes are ignored: they are planned places, not recorded positions.
///
/// GPX files are untrusted input. The parser refuses DOCTYPE declarations outright, which removes the whole
/// class of entity-expansion ("billion laughs") and external-entity (XXE) attacks, caps input size, point
/// count, nesting depth and element-text length, and never crashes on bad input.
public enum GPXParser {
    public static func parse(_ data: Data) throws -> Trace {
        guard data.count <= TraceLimits.maxBytes else {
            throw ParseError(line: 0, message: "input exceeds \(TraceLimits.maxBytes) bytes")
        }
        // A DOCTYPE is where entity definitions live. GPX never needs one, so refuse it before parsing.
        // Checked on the raw bytes, case-insensitively, so it cannot be hidden by odd casing.
        if containsDoctype(data) {
            throw ParseError(line: 0, message: "DOCTYPE declarations are not allowed in GPX files")
        }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        let ok = parser.parse()
        if let e = delegate.failure { throw e }
        if !ok {
            let line = parser.lineNumber
            throw ParseError(line: line, message: "invalid XML: \(parser.parserError?.localizedDescription ?? "parse error")")
        }
        if !delegate.sawRoot { throw ParseError(line: 0, message: "empty document") }
        if delegate.fixes.isEmpty { throw ParseError(line: 0, message: "no <trkpt> trackpoints found") }
        return Trace(fixes: delegate.fixes)
    }

    static func containsDoctype(_ data: Data) -> Bool {
        let needle = Array("<!doctype".utf8)
        let bytes = [UInt8](data)
        if bytes.count < needle.count { return false }
        outer: for i in 0...(bytes.count - needle.count) {
            for j in 0..<needle.count {
                var b = bytes[i + j]
                if b >= 65 && b <= 90 { b += 32 }   // ASCII lowercase
                if b != needle[j] { continue outer }
            }
            return true
        }
        return false
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var fixes: [Fix] = []
        var failure: ParseError?
        var sawRoot = false
        private var depth = 0
        private var current: (lat: Double, lon: Double, line: Int, time: Date?, accuracy: Double?, accuracyExplicit: Bool)?
        private var element: String?
        private var text = ""

        private func fail(_ parser: XMLParser, _ msg: String, line: Int? = nil) {
            if failure == nil { failure = ParseError(line: line ?? parser.lineNumber, message: msg) }
            parser.abortParsing()
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes attrs: [String: String]) {
            depth += 1
            if depth > 32 { fail(parser, "XML nested too deeply"); return }
            let n = name.lowercased()
            if depth == 1 {
                sawRoot = true
                if n != "gpx" { fail(parser, "not a GPX file: root element is <\(name)>"); return }
            }
            if n == "trkpt" {
                if fixes.count >= TraceLimits.maxPoints { fail(parser, "more than \(TraceLimits.maxPoints) points"); return }
                let line = parser.lineNumber
                var lat: Double?, lon: Double?
                for (k, v) in attrs {
                    let key = k.lowercased()
                    if key == "lat" || key == "lon" {
                        do {
                            let d = try CSVParser.parseNumber(v)
                            if key == "lat" { lat = d } else { lon = d }
                        } catch let e as ParseError { fail(parser, "bad \(key): \(e.message)", line: line); return } catch { return }
                    }
                }
                guard let la = lat, let lo = lon else { fail(parser, "<trkpt> needs lat and lon attributes", line: line); return }
                current = (la, lo, line, nil, nil, false)
            } else if current != nil, ["time", "hdop", "accuracy"].contains(n) {
                element = n; text = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard element != nil else { return }
            if text.utf8.count + string.utf8.count > 256 { fail(parser, "unreasonably long text inside a trackpoint element"); return }
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let n = name.lowercased()
            if current != nil, let el = element, n == el {
                let line = parser.lineNumber
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                do {
                    switch el {
                    case "time": current?.time = try CSVParser.parseTime(t)
                    case "accuracy": current?.accuracy = try CSVParser.parseNumber(t); current?.accuracyExplicit = true
                    case "hdop":   // dimensionless; roughly 5 m of error per unit is a common rule of thumb
                        if current?.accuracyExplicit != true { current?.accuracy = try CSVParser.parseNumber(t) * 5 }
                    default: break
                    }
                } catch let e as ParseError { fail(parser, "bad \(el): \(e.message)", line: line); return } catch { return }
                element = nil
            }
            if n == "trkpt", let c = current {
                guard let time = c.time else { fail(parser, "<trkpt> has no <time>; a trace needs timestamps", line: c.line); return }
                fixes.append(Fix(point: GeoPoint(lat: c.lat, lon: c.lon), time: time, accuracyM: c.accuracy, line: c.line))
                current = nil
            }
            depth -= 1
        }
    }
}
