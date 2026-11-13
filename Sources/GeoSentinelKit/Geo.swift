import Foundation

/// A WGS-84 position in decimal degrees.
public struct GeoPoint: Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }

    /// True if both coordinates are finite and in range.
    public var isValid: Bool {
        lat.isFinite && lon.isFinite && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
    }
}

public enum Geo {
    static let earthRadiusM = 6_371_008.8   // mean Earth radius (IUGG), metres

    @inline(__always) static func rad(_ d: Double) -> Double { d * .pi / 180 }

    /// Great-circle (haversine) distance in metres.
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let dLat = rad(b.lat - a.lat), dLon = rad(b.lon - a.lon)
        var h = sin(dLat / 2) * sin(dLat / 2) + cos(rad(a.lat)) * cos(rad(b.lat)) * sin(dLon / 2) * sin(dLon / 2)
        if h > 1 { h = 1 }   // rounding can push antipodal points just above 1
        return 2 * earthRadiusM * asin(h.squareRoot())
    }

    /// Initial bearing from a to b in degrees [0, 360).
    public static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let la1 = rad(a.lat), la2 = rad(b.lat), dLon = rad(b.lon - a.lon)
        let y = sin(dLon) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon)
        let d = atan2(y, x) * 180 / .pi
        return (d + 360).truncatingRemainder(dividingBy: 360)
    }

    /// The point reached by travelling `meters` from `p` on `bearing` degrees.
    public static func destination(_ p: GeoPoint, bearing: Double, meters: Double) -> GeoPoint {
        let ang = meters / earthRadiusM, br = rad(bearing)
        let la1 = rad(p.lat), lo1 = rad(p.lon)
        let la2 = asin(sin(la1) * cos(ang) + cos(la1) * sin(ang) * cos(br))
        let lo2 = lo1 + atan2(sin(br) * sin(ang) * cos(la1), cos(ang) - sin(la1) * sin(la2))
        var lon = (lo2 * 180 / .pi + 540).truncatingRemainder(dividingBy: 360) - 180
        if lon < -180 { lon += 360 }
        return GeoPoint(lat: la2 * 180 / .pi, lon: lon)
    }

    /// Smallest absolute difference between two bearings, in [0, 180].
    public static func angleDiff(_ a: Double, _ b: Double) -> Double {
        var d = abs(a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        return d
    }
}
