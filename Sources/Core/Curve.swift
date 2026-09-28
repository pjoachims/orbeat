import Foundation

/// Chart curves from 1 Hz samples: a centered moving average over a TIME
/// window (not a sample count), so gaps and jittery sample spacing don't
/// skew it, then thinned to a drawable number of points.
enum Curve {
    struct Point: Equatable {
        let t: Double   // seconds since session start
        let v: Double
    }

    /// Mean of all points within ±window/2 of each point; window ≤ 0 = raw.
    static func smooth(_ pts: [Point], window: Double) -> [Point] {
        guard window > 0 else { return pts }
        let half = window / 2
        var lo = 0, hi = 0, sum = 0.0
        return pts.map { p in
            while hi < pts.count, pts[hi].t <= p.t + half { sum += pts[hi].v; hi += 1 }
            while pts[lo].t < p.t - half { sum -= pts[lo].v; lo += 1 }
            return Point(t: p.t, v: sum / Double(hi - lo))
        }
    }

    /// Every n-th point so at most `max` remain (always keeps the last one).
    static func thin(_ pts: [Point], max: Int = 600) -> [Point] {
        let n = Swift.max(1, (pts.count + max - 1) / max)
        guard n > 1 else { return pts }
        var out = stride(from: 0, to: pts.count, by: n).map { pts[$0] }
        if out.last != pts.last, let l = pts.last { out.append(l) }
        return out
    }
}
