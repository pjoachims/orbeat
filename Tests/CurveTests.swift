import Foundation

enum CurveTests {
    static func run() {
        let pts = (0..<10).map { Curve.Point(t: Double($0), v: $0 % 2 == 0 ? 100 : 200) }
        check("curve raw passthrough", Curve.smooth(pts, window: 0) == pts)
        let s = Curve.smooth(pts, window: 2)   // ±1 s → 3-point mean inside
        check("curve centered mean", abs(s[4].v - (200 + 100 + 200) / 3.0) < 1e-9, "\(s[4].v)")
        check("curve edge uses available side", abs(s[0].v - 150) < 1e-9, "\(s[0].v)")
        // A 60 s gap must not be bridged by a 10 s window.
        let gap = [Curve.Point(t: 0, v: 100), Curve.Point(t: 60, v: 300)]
        check("curve window is time, not count", Curve.smooth(gap, window: 10) == gap)
        let long = (0..<3601).map { Curve.Point(t: Double($0), v: 1) }
        let thin = Curve.thin(long)
        check("curve thin bounded (\(thin.count))", thin.count <= 601 && thin.last == long.last)
        check("curve thin short untouched", Curve.thin(pts) == pts)
    }
}
