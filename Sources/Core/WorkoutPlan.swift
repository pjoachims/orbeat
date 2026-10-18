import Foundation

/// The workout builder's editable shape: blocks with power as a fraction of
/// FTP, so a plan survives FTP changes. Expanded to `Workout` steps to ride,
/// written as Zwift .zwo to share.
struct WorkoutPlan: Codable, Equatable {
    enum Kind: String, CaseIterable, Codable { case steady = "Steady", ramp = "Ramp", intervals = "Intervals" }

    /// One shape for all kinds; fields a kind doesn't use are ignored.
    struct Block: Codable, Equatable {
        var kind: Kind
        var seconds = 300          // steady, ramp
        var power = 0.75           // steady; ramp start
        var powerEnd = 0.75        // ramp end
        var repeats = 3            // intervals
        var on = 60, onPower = 1.2
        var off = 60, offPower = 0.5

        var length: Int { kind == .intervals ? repeats * (on + off) : seconds }

        /// (seconds, from, to) as FTP fractions.
        var steps: [(Int, Double, Double)] {
            switch kind {
            case .steady: [(seconds, power, power)]
            case .ramp: [(seconds, power, powerEnd)]
            case .intervals: Array(repeating: [(on, onPower, onPower), (off, offPower, offPower)], count: repeats).flatMap { $0 }
            }
        }

        /// Same block as another kind, keeping its effort (and its time, except as intervals).
        func `as`(_ k: Kind) -> Block {
            let top = kind == .intervals ? onPower : max(power, powerEnd)
            var b = Block(kind: k)
            switch k {
            case .steady: b.seconds = length; b.power = top
            case .ramp: b.seconds = length; b.power = max(0.25, top - 0.25); b.powerEnd = top
            case .intervals: b.on = max(60, length / 6 / 60 * 60); b.off = b.on; b.onPower = max(top, 0.9); b.offPower = 0.55
            }
            return b
        }
    }

    var name: String
    var blocks: [Block]
    /// Rides at this FTP instead of the rider's; nil = the rider's.
    var ftp: Int? = nil

    static let sample = WorkoutPlan(name: "Sweet Spot 3×10", blocks: [
        Block(kind: .ramp, seconds: 600, power: 0.5, powerEnd: 0.75),
        Block(kind: .steady, seconds: 300, power: 0.75),
        Block(kind: .intervals, repeats: 3, on: 600, onPower: 0.9, off: 300, offPower: 0.55),
        Block(kind: .ramp, seconds: 300, power: 0.7, powerEnd: 0.45),
    ])

    /// Starting points for a new plan; the last one is blank.
    static let templates = [
        WorkoutPlan(name: "Endurance 1h", blocks: [
            Block(kind: .ramp, seconds: 300, power: 0.5, powerEnd: 0.65),
            Block(kind: .steady, seconds: 3000, power: 0.68),
            Block(kind: .ramp, seconds: 300, power: 0.6, powerEnd: 0.45),
        ]),
        sample,
        WorkoutPlan(name: "Threshold 2×20", blocks: [
            Block(kind: .ramp, seconds: 600, power: 0.5, powerEnd: 0.75),
            Block(kind: .intervals, repeats: 2, on: 1200, onPower: 0.97, off: 300, offPower: 0.55),
            Block(kind: .ramp, seconds: 300, power: 0.7, powerEnd: 0.45),
        ]),
        WorkoutPlan(name: "VO2 Max 5×3", blocks: [
            Block(kind: .ramp, seconds: 600, power: 0.5, powerEnd: 0.8),
            Block(kind: .steady, seconds: 300, power: 0.6),
            Block(kind: .intervals, repeats: 5, on: 180, onPower: 1.15, off: 180, offPower: 0.5),
            Block(kind: .ramp, seconds: 300, power: 0.6, powerEnd: 0.45),
        ]),
        WorkoutPlan(name: "New Workout", blocks: []),
    ]

    var length: Int { blocks.reduce(0) { $0 + $1.length } }

    func workout(ftp: Int) -> Workout {
        let w = { (f: Double) in Int((f * Double(ftp)).rounded()) }
        return Workout(name: name, steps: blocks.flatMap(\.steps).map { .init(seconds: Double($0.0), from: w($0.1), to: w($0.2)) })
    }

    /// Mean power as an FTP fraction (ramps at their midpoint).
    var intensity: Double {
        let st = blocks.flatMap(\.steps), t = st.reduce(0) { $0 + $1.0 }
        return t == 0 ? 0 : st.reduce(0) { $0 + Double($1.0) * ($1.1 + $1.2) / 2 } / Double(t)
    }

    /// Normalised power as an FTP fraction: 30 s rolling mean, fourth-power average.
    var intensityFactor: Double {
        let p = blocks.flatMap(\.steps).flatMap { s, a, e in (0..<s).map { a + (e - a) * (Double($0) + 0.5) / Double(s) } }
        guard p.count >= 30 else { return intensity }
        var sum = p[0..<30].reduce(0, +), acc = 0.0
        for i in 30...p.count {
            acc += pow(sum / 30, 4)
            if i < p.count { sum += p[i] - p[i - 30] }
        }
        return pow(acc / Double(p.count - 29), 0.25)
    }

    var tss: Int { Int((Double(length) / 3600 * intensityFactor * intensityFactor * 100).rounded()) }

    var zwo: String {
        let f = { (x: Double) in String(format: "%.3f", x) }
        let name = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let body = blocks.map { b in
            switch b.kind {
            case .steady: "    <SteadyState Duration=\"\(b.seconds)\" Power=\"\(f(b.power))\"/>"
            case .ramp: "    <Ramp Duration=\"\(b.seconds)\" PowerLow=\"\(f(b.power))\" PowerHigh=\"\(f(b.powerEnd))\"/>"
            case .intervals: "    <IntervalsT Repeat=\"\(b.repeats)\" OnDuration=\"\(b.on)\" OffDuration=\"\(b.off)\" OnPower=\"\(f(b.onPower))\" OffPower=\"\(f(b.offPower))\"/>"
            }
        }.joined(separator: "\n")
        return "<workout_file>\n  <author>Orbeat</author>\n  <name>\(name)</name>\n  <sportType>bike</sportType>\n  <workout>\n\(body)\n  </workout>\n</workout_file>\n"
    }
}
