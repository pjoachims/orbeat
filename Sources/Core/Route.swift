import Foundation

/// A route to ride in sim: elevation over distance, from a GPX file. The ride
/// advances along it at road-model speed and the trainer follows its grade.
struct Route: Codable, Equatable {
    var name: String
    /// Metres from the start, strictly increasing; `ele` is metres above sea level.
    var dist: [Double]
    var ele: [Double]

    var length: Double { dist.last ?? 0 }

    /// Grade window: GPX elevation is noisy point to point (±15 % spikes);
    /// the slope over 100 m is what a rider feels.
    static let window = 100.0

    /// Terrain grade at `d` metres, in TrainerMode's 0.01 % units.
    func grade(at d: Double) -> Int {
        let lo = max(0, d - Self.window / 2), hi = min(length, d + Self.window / 2)
        guard hi - lo >= 1 else { return 0 }
        let g = Int(((elevation(at: hi) - elevation(at: lo)) / (hi - lo) * 10_000).rounded())
        return min(TrainerMode.gradeRange.upperBound, max(TrainerMode.gradeRange.lowerBound, g))
    }

    /// Linear interpolation between points, clamped to the ends.
    func elevation(at d: Double) -> Double {
        guard let last = dist.indices.last else { return 0 }
        if d <= 0 { return ele[0] }
        if d >= length { return ele[last] }
        var lo = 0, hi = last   // binary search: dist[lo] <= d < dist[hi]
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if dist[mid] <= d { lo = mid } else { hi = mid }
        }
        let t = (d - dist[lo]) / (dist[hi] - dist[lo])
        return ele[lo] + t * (ele[hi] - ele[lo])
    }

    /// Total climb in metres, on the same 100 m scale as the grade.
    var climb: Double {
        stride(from: 0, to: length, by: Self.window).reduce(0) { sum, d in
            sum + max(0, elevation(at: min(length, d + Self.window)) - elevation(at: d))
        }
    }

    /// GPX 1.1 track (trkpt) or route (rtept) points with <ele>. nil when it
    /// has no elevation — nothing to ride.
    static func gpx(_ data: Data, name fallback: String) -> Route? {
        let p = GPXParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        guard xml.parse(), p.points.count >= 2, p.points.contains(where: { $0.ele != nil }) else { return nil }
        var dist: [Double] = [], ele: [Double] = []
        var prev: (lat: Double, lon: Double)?
        var d = 0.0, lastEle = p.points.first { $0.ele != nil }!.ele!
        for pt in p.points {
            if let prev { d += haversine(prev, (pt.lat, pt.lon)) }
            prev = (pt.lat, pt.lon)
            lastEle = pt.ele ?? lastEle   // a point without <ele> keeps the previous one
            if let last = dist.last, d - last < 5 { continue }   // duplicates out, dense tracks thinned (100 m window)
            dist.append(d)
            ele.append(lastEle)
        }
        guard dist.count >= 2 else { return nil }
        return Route(name: p.name ?? fallback, dist: dist, ele: ele)
    }

    private static func haversine(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let r = 6_371_000.0, rad = Double.pi / 180
        let dLat = (b.0 - a.0) * rad, dLon = (b.1 - a.1) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.0 * rad) * cos(b.0 * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}

private final class GPXParser: NSObject, XMLParserDelegate {
    var points: [(lat: Double, lon: Double, ele: Double?)] = []
    var name: String?
    private var text = ""
    private var inPoint = false, inWpt = false   // a waypoint's <ele>/<name> isn't ours

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes a: [String: String] = [:]) {
        text = ""
        if el == "wpt" { inWpt = true }
        if el == "trkpt" || el == "rtept", let lat = a["lat"].flatMap(Double.init), let lon = a["lon"].flatMap(Double.init) {
            points.append((lat, lon, nil))
            inPoint = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if el == "trkpt" || el == "rtept" { inPoint = false }
        if el == "wpt" { inWpt = false }
        if el == "ele", inPoint, let e = Double(t) { points[points.count - 1].ele = e }
        if el == "name", !inPoint, !inWpt, name == nil, points.isEmpty, !t.isEmpty { name = t }   // first name before any point: the track's
    }
}
