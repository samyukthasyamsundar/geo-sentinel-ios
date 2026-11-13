import Foundation

/// One reported position.
public struct Fix: Equatable, Sendable {
    public var point: GeoPoint
    public var time: Date
    /// Reported horizontal accuracy radius in metres, or nil if absent.
    public var accuracyM: Double?
    /// 1-based source line, for error reporting (0 for fixes recorded live).
    public var line: Int
    public init(point: GeoPoint, time: Date, accuracyM: Double? = nil, line: Int = 0) {
        self.point = point; self.time = time; self.accuracyM = accuracyM; self.line = line
    }
}

public struct Trace: Sendable {
    public var fixes: [Fix]
    public init(fixes: [Fix]) { self.fixes = fixes }

    /// A copy ordered by time (stable), and whether the input was already in order.
    public func sortedByTime() -> (trace: Trace, wasInOrder: Bool) {
        var inOrder = true
        if fixes.count > 1 {
            for i in 1..<fixes.count where fixes[i].time < fixes[i - 1].time { inOrder = false; break }
        }
        // Swift's sort is not guaranteed stable, so break ties by original position.
        let indexed = fixes.enumerated().sorted {
            $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset
        }
        return (Trace(fixes: indexed.map { $0.element }), inOrder)
    }
}

public struct ParseError: Error, Equatable, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { line > 0 ? "line \(line): \(message)" : message }
}

public enum TraceLimits {
    /// 500k points is several days of 1 Hz tracking.
    public static let maxPoints = 500_000
    public static let maxBytes = 64 << 20
}
