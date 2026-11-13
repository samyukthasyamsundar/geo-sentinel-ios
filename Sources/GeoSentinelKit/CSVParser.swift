import Foundation

public enum CSVParser {
    /// Parses a CSV trace. The first row is a header naming the columns, in any order:
    ///   time (required: RFC 3339 or Unix seconds), lat, lon (required), accuracy (optional, metres).
    /// Stops at the first malformed row and reports its line. Never crashes on bad input.
    public static func parse(_ data: Data) throws -> Trace {
        guard data.count <= TraceLimits.maxBytes else {
            throw ParseError(line: 0, message: "input exceeds \(TraceLimits.maxBytes) bytes")
        }
        guard var text = String(data: data, encoding: .utf8) else {
            throw ParseError(line: 0, message: "file is not valid UTF-8 text")
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }   // byte order mark

        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { String($0) }
        // A trailing newline leaves one empty final element.
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        guard let headerLine = lines.first else { throw ParseError(line: 1, message: "empty file: expected a header row") }

        let header = split(headerLine).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var cols: [String: Int] = [:]
        for (i, name) in header.enumerated() where !name.isEmpty {
            if cols[name] != nil { throw ParseError(line: 1, message: "duplicate column \"\(name)\"") }
            cols[name] = i
        }
        for need in ["time", "lat", "lon"] where cols[need] == nil {
            throw ParseError(line: 1, message: "missing required column \"\(need)\" (have: \(header.joined(separator: ",")))")
        }
        let ti = cols["time"]!, la = cols["lat"]!, lo = cols["lon"]!, ai = cols["accuracy"]
        let maxIdx = max(ti, la, lo, ai ?? 0)

        var fixes: [Fix] = []
        for (offset, raw) in lines.dropFirst().enumerated() {
            let lineNo = offset + 2
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if fixes.count >= TraceLimits.maxPoints {
                throw ParseError(line: lineNo, message: "more than \(TraceLimits.maxPoints) points")
            }
            if raw.contains("\"") { throw ParseError(line: lineNo, message: "quoted fields are not supported") }
            let f = split(raw)
            if f.count <= maxIdx { throw ParseError(line: lineNo, message: "row has \(f.count) columns, need at least \(maxIdx + 1)") }

            let time: Date
            do { time = try parseTime(f[ti]) } catch let e as ParseError { throw ParseError(line: lineNo, message: "bad time: \(e.message)") }
            let lat: Double, lon: Double
            do { lat = try parseNumber(f[la]) } catch let e as ParseError { throw ParseError(line: lineNo, message: "bad lat: \(e.message)") }
            do { lon = try parseNumber(f[lo]) } catch let e as ParseError { throw ParseError(line: lineNo, message: "bad lon: \(e.message)") }
            var acc: Double? = nil
            if let ai, !f[ai].trimmingCharacters(in: .whitespaces).isEmpty {
                do { acc = try parseNumber(f[ai]) } catch let e as ParseError { throw ParseError(line: lineNo, message: "bad accuracy: \(e.message)") }
            }
            fixes.append(Fix(point: GeoPoint(lat: lat, lon: lon), time: time, accuracyM: acc, line: lineNo))
        }
        if fixes.isEmpty { throw ParseError(line: 0, message: "no data rows") }
        return Trace(fixes: fixes)
    }

    private static func split(_ s: String) -> [String] { s.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }

    /// Plain finite decimals only: rejects NaN, infinity, hex floats and empty strings.
    static func parseNumber(_ raw: String) throws -> Double {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { throw ParseError(line: 0, message: "empty value") }
        if s.contains(where: { "xXpP".contains($0) }) { throw ParseError(line: 0, message: "\"\(s)\" is not a plain decimal") }
        guard let v = Double(s) else { throw ParseError(line: 0, message: "\"\(s)\" is not a number") }
        if !v.isFinite { throw ParseError(line: 0, message: "\"\(s)\" is not finite") }
        return v
    }

    /// RFC 3339 or Unix seconds (bounded to 1970-2100 so huge values cannot overflow date arithmetic).
    static func parseTime(_ raw: String) throws -> Date {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { throw ParseError(line: 0, message: "empty value") }
        for opts in [ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]), [.withInternetDateTime]] {
            let f = ISO8601DateFormatter()
            f.formatOptions = opts
            if let d = f.date(from: s) { return d }
        }
        guard let v = try? parseNumber(s) else {
            throw ParseError(line: 0, message: "\"\(s)\" is neither RFC 3339 nor Unix seconds")
        }
        if v < 0 || v > 4_102_444_800 { throw ParseError(line: 0, message: "Unix time \(v) is outside 1970-2100") }
        return Date(timeIntervalSince1970: v)
    }
}
