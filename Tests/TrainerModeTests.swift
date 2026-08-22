import Foundation

/// TrainerMode clamping, stepping and labels.
struct TrainerModeTests {
    static func run() {
        check("erg clamp high", TrainerMode.erg(targetWatts: 700).clamped == .erg(targetWatts: 600))
        check("erg clamp low", TrainerMode.erg(targetWatts: 5).clamped == .erg(targetWatts: 30))
        check("erg step up", TrainerMode.erg(targetWatts: 200).steppedUp == .erg(targetWatts: 210))
        check("erg step up clamped", TrainerMode.erg(targetWatts: 600).steppedUp == .erg(targetWatts: 600))
        check("erg step down clamped", TrainerMode.erg(targetWatts: 30).steppedDown == .erg(targetWatts: 30))
        check("sim step down", TrainerMode.sim(grade: 300).steppedDown == .sim(grade: 200))
        check("sim clamp low", TrainerMode.sim(grade: -600).clamped == .sim(grade: -500))
        check("sim clamp high", TrainerMode.sim(grade: 1600).steppedUp == .sim(grade: 1500))
        check("resistance step", TrainerMode.resistance(percent: 95).steppedUp == .resistance(percent: 100))
        check("labels", TrainerMode.erg(targetWatts: 200).label == "ERG · 200 W"
            && TrainerMode.sim(grade: 150).label == "Sim · 1.5 %"
            && TrainerMode.resistance(percent: 40).label == "Resistance · 40 %")
        check("step labels", TrainerMode.erg(targetWatts: 200).stepLabel == "+10 W"
            && TrainerMode.sim(grade: 150).stepLabel == "+1 %")
    }
}

private extension TrainerMode {
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
