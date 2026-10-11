import Foundation

enum RouteTests {
    static func run() {
        // 1 km due north (0.008993° lat ≈ 1000 m), climbing 50 m, then flat.
        let gpx = """
        <?xml version="1.0"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <wpt lat="47.1" lon="11.1"><ele>9999</ele><name>Hut</name></wpt>
          <trk><name>Test Climb</name><trkseg>
            <trkpt lat="47.0" lon="11.0"><ele>500</ele></trkpt>
            <trkpt lat="47.0" lon="11.0"><ele>500</ele></trkpt>
            <trkpt lat="47.004496" lon="11.0"></trkpt>
            <trkpt lat="47.008993" lon="11.0"><ele>550</ele></trkpt>
            <trkpt lat="47.017986" lon="11.0"><ele>550</ele></trkpt>
          </trkseg></trk>
        </gpx>
        """
        guard let r = Route.gpx(Data(gpx.utf8), name: "file") else { return check("gpx parses", false) }
        check("gpx name from track, not waypoint", r.name == "Test Climb", r.name)
        check("gpx drops duplicate point", r.dist.count == 4, "\(r.dist)")
        check("gpx length ≈ 2 km", abs(r.length - 2000) < 5, "\(r.length)")
        check("point without ele keeps previous", r.ele[1] == 500)
        check("flat until the gap point", r.grade(at: 250) == 0)
        check("10 % from the gap point up", r.grade(at: 750) == 1000, "\(r.grade(at: 750))")
        check("flat after", r.grade(at: 1600) == 0)
        check("grade smoothed over the kink", (0...1000).contains(r.grade(at: 1000)))
        check("climb ≈ 50 m", abs(r.climb - 50) < 1, "\(r.climb)")
        check("elevation clamps", r.elevation(at: -10) == 500 && r.elevation(at: 9e9) == 550)
        let steep = Route(name: "wall", dist: [0, 100], ele: [0, 40])
        check("grade clamps to trainer range", steep.grade(at: 50) == TrainerMode.gradeRange.upperBound)
        check("gpx without elevation is nil", Route.gpx(Data("""
            <gpx><trk><trkseg><trkpt lat="1" lon="1"/><trkpt lat="1.01" lon="1"/></trkseg></trk></gpx>
            """.utf8), name: "x") == nil)
        check("route-style gpx (rtept)", Route.gpx(Data("""
            <gpx><rte><rtept lat="1" lon="1"><ele>1</ele></rtept><rtept lat="1.01" lon="1"><ele>2</ele></rtept></rte></gpx>
            """.utf8), name: "fallback")?.name == "fallback")
        check("garbage is nil", Route.gpx(Data("nope".utf8), name: "x") == nil)
    }
}
