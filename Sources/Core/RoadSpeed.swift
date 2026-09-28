import Foundation

/// Virtual road speed from power, like Zwift: the trainer's own wheel speed
/// is meaningless in ERG (it follows the flywheel), so speed and distance
/// come from a steady-state road model instead.
/// ponytail: fixed rider (85 kg incl. bike, CdA 0.32, Crr 0.004); make them
/// settings if riders differ a lot.
enum RoadSpeed {
    static let massKg = 85.0, cdA = 0.32, crr = 0.004, rho = 1.2, g = 9.81

    /// km/h holding `watts` on `gradePercent`; 0 when not pedalling.
    static func kmh(watts: Int, gradePercent: Double = 0) -> Double {
        guard watts > 0 else { return 0 }
        let p = Double(watts)
        let a = 0.5 * rho * cdA
        let b = massKg * g * (crr + gradePercent / 100)
        // P(v) = v·(b + a·v²): one crossing above P > 0 even when b < 0 (downhill).
        var lo = 0.0, hi = 40.0   // m/s
        for _ in 0..<50 {
            let v = (lo + hi) / 2
            if v * (b + a * v * v) < p { lo = v } else { hi = v }
        }
        return lo * 3.6
    }
}
