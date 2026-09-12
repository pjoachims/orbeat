import Foundation

/// Trainer control target — one type for every FTMS mode the app supports.
/// App policy steps modes with `steppedUp/steppedDown`; the Trainer component
/// clamps and encodes them onto the FTMS control point.
enum TrainerMode: Equatable {
    /// ERG: trainer holds a constant power regardless of cadence.
    case erg(targetWatts: Int)
    /// Resistance level as a percentage of the trainer's range.
    case resistance(percent: Int)
    /// Simulation: resistance scales with speed like a real hill. Grade in
    /// 0.01 % units; wind/crr/cw stay flat (0).
    case sim(grade: Int)

    // Ranges and step sizes (per paddle press / Harder-Easier menu item).
    static let wattRange = 30...600
    static let percentRange = 0...100
    static let gradeRange = -500...1500   // -5 % … +15 %

    var clamped: TrainerMode {
        switch self {
        case .erg(let w):
            return .erg(targetWatts: min(Self.wattRange.upperBound, max(Self.wattRange.lowerBound, w)))
        case .resistance(let p):
            return .resistance(percent: min(Self.percentRange.upperBound, max(Self.percentRange.lowerBound, p)))
        case .sim(let g):
            return .sim(grade: min(Self.gradeRange.upperBound, max(Self.gradeRange.lowerBound, g)))
        }
    }

    var steppedUp: TrainerMode {
        switch self {
        case .erg(let w): return TrainerMode.erg(targetWatts: w + 10).clamped
        case .resistance(let p): return TrainerMode.resistance(percent: p + 10).clamped
        case .sim(let g): return TrainerMode.sim(grade: g + 100).clamped
        }
    }

    var steppedDown: TrainerMode {
        switch self {
        case .erg(let w): return TrainerMode.erg(targetWatts: w - 10).clamped
        case .resistance(let p): return TrainerMode.resistance(percent: p - 10).clamped
        case .sim(let g): return TrainerMode.sim(grade: g - 100).clamped
        }
    }

}

extension TrainerMode {
    /// Human-readable current target, for menus and HUDs.
    var label: String {
        switch self {
        case .erg(let w): return "ERG · \(w) W"
        case .resistance(let p): return "Resistance · \(p) %"
        case .sim(let g): return String(format: "Sim · %.1f %%", Double(g) / 100)
        }
    }

    /// Label for one step in this mode, e.g. "+10 W".
    var stepLabel: String {
        switch self {
        case .erg: return "+10 W"
        case .resistance: return "+10 %"
        case .sim: return "+1 %"
        }
    }
}
