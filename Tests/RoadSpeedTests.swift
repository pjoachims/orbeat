import Foundation

enum RoadSpeedTests {
    static func run() {
        let flat = RoadSpeed.kmh(watts: 140)
        check("speed 140 W flat ≈ 30 km/h (\(flat))", abs(flat - 30) < 1.5)
        check("speed 0 W → 0", RoadSpeed.kmh(watts: 0) == 0)
        check("speed climbs slower", RoadSpeed.kmh(watts: 200, gradePercent: 8) < 15)
        check("speed descends faster", RoadSpeed.kmh(watts: 100, gradePercent: -3) > RoadSpeed.kmh(watts: 100))
        check("speed monotonic in watts", RoadSpeed.kmh(watts: 250) > RoadSpeed.kmh(watts: 200))
    }
}
