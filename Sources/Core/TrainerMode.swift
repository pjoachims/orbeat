import Foundation

/// Trainer control target — one type for every FTMS mode the app supports.
/// App policy steps modes with `steppedUp/steppedDown`; the Trainer component
/// clamps and encodes them onto the FTMS control point.
enum TrainerMode: Equatable {
    /// ERG: trainer holds a constant power regardless of cadence.
    case erg(targetWatts: Int)
    /// Resistance level as a percentage of the trainer's range.
    case resistance(percent: Int)
    /// Simulation: resistance scales with speed like a real hill. Grade is
    /// the terrain in 0.01 % units; gear is the virtual gear (1…24, Zwift's
    /// table). The trainer gets `simParams`.
    case sim(grade: Int, gear: Int = TrainerMode.neutralGear)

    // Ranges and step sizes (per paddle press / Harder-Easier menu item).
    static let wattRange = 30...600
    static let percentRange = 0...100
    static let gradeRange = -500...1500   // terrain: -5 % … +15 %
    static let gearRange = 1...24
    static let neutralGear = 12

    /// Zwift's virtual gear ratios (chainring/cog, gear 1…24).
    static let gearRatios = [0.75, 0.87, 0.99, 1.11, 1.23, 1.38, 1.53, 1.68, 1.86, 2.04, 2.22, 2.40,
                             2.61, 2.82, 3.03, 3.24, 3.49, 3.74, 3.99, 4.24, 4.54, 4.84, 5.14, 5.49]

    /// Ratio the trainer is assumed to be ridden in: 34×14, the Zwift Cog
    /// (Zwift's gear 12). ponytail: fixed; Zwift-Protocol trainers detect the
    /// real gear themselves, only the FTMS fallback relies on it.
    static let trainerRatio = 34.0 / 14

    /// Grade the trainer gets, Zwift's Trainer Difficulty: climbs × difficulty,
    /// descents halved first, then × difficulty. 0.01 % units.
    func sentGrade(difficulty: Int) -> Int? {
        guard case .sim(let g, _) = self else { return nil }
        return Int((Double(g) * (g < 0 ? 0.5 : 1) * Double(difficulty) / 100).rounded())
    }

    /// Gear ratio of the current sim gear (chainring/cog).
    var gearRatio: Double? {
        guard case .sim(_, let gear) = self else { return nil }
        return Self.gearRatios[gear - 1]
    }

    /// FTMS fallback for trainers without Zwift Protocol: Zwift's road (Crr
    /// 0.004, CWa 0.51) scaled for the virtual gear. The trainer turns these
    /// into flywheel force at ITS speed, the real gear's. Virtual ratio r at
    /// the same cadence means road speed × k and pedal force × k, with
    /// k = r / trainerRatio; air drag goes with speed², so: grade × k,
    /// crr × k, cw × k³. cw saturates at 2.55 from about gear 18 on.
    func simParams(rider: Rider) -> SimParams? {
        guard let sent = sentGrade(difficulty: rider.difficulty), let r = gearRatio else { return nil }
        let k = r / Self.trainerRatio
        func clamp(_ x: Double, _ r: ClosedRange<Int>) -> Int { min(r.upperBound, max(r.lowerBound, Int(x.rounded()))) }
        // Downhill, grade pushes and cw brakes: once cw saturates, scaling the
        // grade further would make bigger gears easier. Cap k there.
        let kCw = pow(2.55 / Self.zwiftCWa, 1.0 / 3)
        return SimParams(grade: clamp(Double(sent) * (sent < 0 ? min(k, kCw) : k), -4000...4000),   // ±40 %; trainers cap lower themselves
                         crr: clamp(Self.zwiftCrr * k * 10_000, 0...255),
                         cw: clamp(Self.zwiftCWa * k * k * k * 100, 0...255))
    }

    /// Road Zwift sends the trainer, on FTMS and Zwift Protocol alike.
    static let zwiftCrr = 0.004, zwiftCWa = 0.51

    var clamped: TrainerMode {
        switch self {
        case .erg(let w):
            return .erg(targetWatts: min(Self.wattRange.upperBound, max(Self.wattRange.lowerBound, w)))
        case .resistance(let p):
            return .resistance(percent: min(Self.percentRange.upperBound, max(Self.percentRange.lowerBound, p)))
        case .sim(let g, let gear):
            return .sim(grade: min(Self.gradeRange.upperBound, max(Self.gradeRange.lowerBound, g)),
                        gear: min(Self.gearRange.upperBound, max(Self.gearRange.lowerBound, gear)))
        }
    }

    var steppedUp: TrainerMode {
        switch self {
        case .erg(let w): return TrainerMode.erg(targetWatts: w + 5).clamped
        case .resistance(let p): return TrainerMode.resistance(percent: p + 10).clamped
        case .sim(let g, let gear): return TrainerMode.sim(grade: g, gear: gear + 1).clamped
        }
    }

    var steppedDown: TrainerMode {
        switch self {
        case .erg(let w): return TrainerMode.erg(targetWatts: w - 5).clamped
        case .resistance(let p): return TrainerMode.resistance(percent: p - 10).clamped
        case .sim(let g, let gear): return TrainerMode.sim(grade: g, gear: gear - 1).clamped
        }
    }

}

extension TrainerMode {
    /// Human-readable current target, for menus and HUDs.
    func sameKind(as other: TrainerMode?) -> Bool {
        switch (self, other) {
        case (.erg, .erg?), (.resistance, .resistance?), (.sim, .sim?): return true
        default: return false
        }
    }

    /// This kind at its last-used target: the picker switches kind, the value
    /// comes back from memory. Resistance has no memory.
    func resumed(ergWatts: Int, grade: Int, gear: Int) -> TrainerMode {
        switch self {
        case .erg: return .erg(targetWatts: ergWatts)
        case .sim: return .sim(grade: grade, gear: gear)
        case .resistance: return self
        }
    }

    var label: String {
        switch self {
        case .erg(let w): return "ERG · \(w) W"
        case .resistance(let p): return "Resistance · \(p) %"
        case .sim(let g, let gear): return String(format: "%.1f %% · Gear %d", Double(g) / 100, gear)
        }
    }

    /// Label for one step in this mode, e.g. "+5 W".
    var stepLabel: String {
        switch self {
        case .erg: return "+5 W"
        case .resistance: return "+10 %"
        case .sim: return "+1 gear"
        }
    }
}

/// FTMS Indoor Bike Simulation Parameters (control 0x11 / status 0x12 payload).
struct SimParams: Equatable {
    var grade: Int   // 0.01 %
    var crr: Int     // 0.0001
    var cw: Int      // wind resistance ½ρCdA, 0.01 kg/m

    /// wind(sint16, mm/s)=0, grade(sint16), crr(uint8), cw(uint8).
    var bytes: [UInt8] {
        let u = UInt16(bitPattern: Int16(grade))
        return [0, 0, UInt8(u & 0xFF), UInt8(u >> 8), UInt8(crr), UInt8(cw)]
    }
}

/// Rider settings the trainer needs for Zwift-style sim. Persisted; the
/// trainer owner's copy is what the trainer gets.
struct Rider: Equatable, Codable {
    var riderKg = 80
    var bikeKg = 8
    /// Zwift's Trainer Difficulty, 0…100 %.
    var difficulty = 50
    var massKg: Double { Double(riderKg + bikeKg) }

    static let riderRange = 40...150, bikeRange = 5...25
    static let difficulties = [0, 25, 50, 75, 100]

    enum CodingKeys: String, CodingKey { case riderKg = "r", bikeKg = "b", difficulty = "d" }

    /// Within the settings' ranges: values also arrive from the peer link.
    var clamped: Rider {
        Rider(riderKg: min(max(riderKg, Self.riderRange.lowerBound), Self.riderRange.upperBound),
              bikeKg: min(max(bikeKg, Self.bikeRange.lowerBound), Self.bikeRange.upperBound),
              difficulty: min(max(difficulty, 0), 100))
    }
}
