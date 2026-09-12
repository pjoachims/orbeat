import Foundation

/// FTMS Fitness Machine Status (0x2ADA) → the trainer's current target.
/// The trainer notifies EVERY connected central when ANY of them changes a
/// target, so this is how two Orbeat apps on one KICKR stay in sync.
/// Only the three opcodes that map onto `TrainerMode` are decoded.
enum FtmsMachineStatus {
    static func parse(_ b: [UInt8]) -> TrainerMode? {
        guard b.count >= 2 else { return nil }
        func s16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8)) }
        switch b[0] {
        case 0x07:  // Target Resistance Level Changed: u8 (spec) or s16 (some trainers), 0.1 units
            let raw = b.count >= 3 ? s16(1) : Int(b[1])
            return .resistance(percent: raw / 10)
        case 0x08:  // Target Power Changed: s16 W
            guard b.count >= 3 else { return nil }
            return .erg(targetWatts: s16(1))
        case 0x12:  // Indoor Bike Simulation Parameters Changed: wind s16, grade s16 (0.01 %), crr u8, cw u8
            guard b.count >= 5 else { return nil }
            return .sim(grade: s16(3))
        default:
            return nil
        }
    }
}

extension FtmsMachineStatus {
    /// The status frame a trainer would notify for `mode` — synthesized by a
    /// bridge for its own control-point writes, because a KICKR notifies
    /// 0x2ADA to every central EXCEPT the one that wrote.
    static func encode(_ m: TrainerMode) -> [UInt8] {
        func le(_ v: Int) -> [UInt8] { let u = UInt16(bitPattern: Int16(v)); return [UInt8(u & 0xFF), UInt8(u >> 8)] }
        switch m {
        case .erg(let w): return [0x08] + le(w)
        case .resistance(let p): return [0x07] + le(p * 10)
        case .sim(let g): return [0x12, 0, 0] + le(g) + [0, 0]
        }
    }
}

/// FTMS Control Point (0x2AD9) write → the target it sets. Inverse of
/// `Trainer.set`'s encoding; lets a bridge learn what a downstream client
/// wrote through it.
enum FtmsControlFrame {
    static func parse(_ b: [UInt8]) -> TrainerMode? {
        guard b.count >= 3 else { return nil }
        func s16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8)) }
        switch b[0] {
        case 0x04: return .resistance(percent: s16(1) / 10)
        case 0x05: return .erg(targetWatts: s16(1))
        case 0x11: return b.count >= 5 ? .sim(grade: s16(3)) : nil
        default: return nil
        }
    }
}
