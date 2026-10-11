import Foundation

/// TrainerMode clamping, stepping and labels.
struct TrainerModeTests {
    static func run() {
        check("erg clamp high", TrainerMode.erg(targetWatts: 700).clamped == .erg(targetWatts: 600))
        check("erg clamp low", TrainerMode.erg(targetWatts: 5).clamped == .erg(targetWatts: 30))
        check("erg step up", TrainerMode.erg(targetWatts: 200).steppedUp == .erg(targetWatts: 205))
        check("erg step up clamped", TrainerMode.erg(targetWatts: 600).steppedUp == .erg(targetWatts: 600))
        check("erg step down clamped", TrainerMode.erg(targetWatts: 30).steppedDown == .erg(targetWatts: 30))
        check("sim step = gear", TrainerMode.sim(grade: 300, gear: 12).steppedDown == .sim(grade: 300, gear: 11))
        check("sim clamp low", TrainerMode.sim(grade: -600).clamped == .sim(grade: -500))
        check("gear clamp high", TrainerMode.sim(grade: 1600, gear: 24).steppedUp == .sim(grade: 1500, gear: 24))
        check("gear clamp low", TrainerMode.sim(grade: 0, gear: 1).steppedDown == .sim(grade: 0, gear: 1))
        // Trainer Difficulty (Zwift): climbs × d, descents halved then × d.
        check("difficulty climbs", TrainerMode.sim(grade: 800).sentGrade(difficulty: 50) == 400)
        check("difficulty descents", TrainerMode.sim(grade: -1000).sentGrade(difficulty: 100) == -500
            && TrainerMode.sim(grade: -1000).sentGrade(difficulty: 50) == -250)
        check("difficulty 0 is flat", TrainerMode.sim(grade: 1500).sentGrade(difficulty: 0) == 0)
        check("rider clamped", Rider(riderKg: -1, bikeKg: 99, difficulty: 1_000_000).clamped == Rider(riderKg: 40, bikeKg: 25, difficulty: 100))
        let full = Rider(riderKg: 80, bikeKg: 8, difficulty: 100)
        // FTMS fallback. Gear 12 on 34×14: k = 2.40 / 2.4286 ≈ 0.99.
        let one = TrainerMode.sim(grade: 500).simParams(rider: full)!
        check("neutral gear ≈ Zwift's road", one == SimParams(grade: 494, crr: 40, cw: 49), "\(one)")
        check("sim bytes", one.bytes == [0, 0, 0xEE, 0x01, 40, 49])
        // Flywheel force the trainer applies at 90 rpm in the real gear, from the params.
        func force(_ g: Int, _ gear: Int) -> Double {
            let p = TrainerMode.sim(grade: g, gear: gear).simParams(rider: full)!
            let v = 1.5 * TrainerMode.trainerRatio * 2.105
            return full.massKg * 9.81 * Double(p.grade + p.crr) / 10_000 + Double(p.cw) / 100 * v * v
        }
        for g in [-500, -200, 0, 500, 1500] {
            let f = TrainerMode.gearRange.map { max(0, force(g, $0)) }   // < 0: spun out, trainer at its floor
            check("shift up never easier at \(g)", zip(f, f.dropFirst()).allSatisfy { $0 <= $1 } && f.last! > 0, "\(f)")
        }
        check("small gear spins out downhill", force(-500, 1) < 0)
        check("cw saturates in big gears", TrainerMode.sim(grade: 0, gear: 24).simParams(rider: full)!.cw == 255)
        check("erg has no sim params", TrainerMode.erg(targetWatts: 200).simParams(rider: full) == nil
            && ZwiftHub.frames(.erg(targetWatts: 200), rider: full) == nil)

        // Zwift Protocol: byte-identical to frames qdomyos-zwift sends a Zwift hub.
        check("zwift sim frame", ZwiftHub.simulation(grade: 173)
            == [0x04, 0x22, 0x0b, 0x08, 0x00, 0x10, 0xda, 0x02, 0x18, 0xec, 0x27, 0x20, 0x90, 0x03])
        check("zwift negative grade zigzags", ZwiftHub.simulation(grade: -1)[5...6] == [0x10, 0x01])
        let qzRider = Rider(riderKg: 85, bikeKg: 8, difficulty: 50)
        let phys = ZwiftHub.physical(gearRatio: 2.4, rider: qzRider)
        check("zwift physical frame", phys == [0x04, 0x2a, 0x0a, 0x10, 0xc0, 0xbb, 0x01, 0x20, 0xa0, 0x06, 0x28, 0xb4, 0x42],
              phys.map { String(format: "%02x", $0) }.joined())
        let f = ZwiftHub.frames(.sim(grade: 800, gear: 24), rider: qzRider)!
        check("zwift frames: difficulty grade first, then gear", f == [ZwiftHub.simulation(grade: 400),
                                                                     ZwiftHub.physical(gearRatio: 5.49, rider: qzRider)])
        check("resistance step", TrainerMode.resistance(percent: 95).steppedUp == .resistance(percent: 100))
        check("labels", TrainerMode.erg(targetWatts: 200).label == "ERG · 200 W"
            && TrainerMode.sim(grade: 150, gear: 8).label == "1.5 % · Gear 8"
            && TrainerMode.resistance(percent: 40).label == "Resistance · 40 %")
        check("step labels", TrainerMode.erg(targetWatts: 200).stepLabel == "+5 W"
            && TrainerMode.sim(grade: 150).stepLabel == "+1 gear")
        check("resume kind", TrainerMode.erg(targetWatts: 120).resumed(ergWatts: 175, grade: 250, gear: 7) == .erg(targetWatts: 175)
            && TrainerMode.sim(grade: 0).resumed(ergWatts: 175, grade: 250, gear: 7) == .sim(grade: 250, gear: 7))
    }
}
