import Foundation

/// Parses standard BLE Cycling Power Measurement packets (0x2A63) and derives
/// speed/cadence from cumulative wheel/crank revolution deltas. One instance
/// per connected power device — the rev counters are per-device state; call
/// `reset()` on disconnect.
///
/// Spec: flags UInt16 LE, instantaneous power SInt16 LE, then optional fields
/// in flag-bit order: bit0 pedal balance, bit2 accumulated torque,
/// bit4 wheel revolution data, bit5 crank revolution data.
final class CyclingPowerParser {
    /// Raw packet contents + derived values, for logging and the UI reading.
    struct Packet {
        let device: String?
        let watts: Int
        let balancePct: Double?
        let torqueNm: Double?
        let kmh: Double?
        let rpm: Int?
        let wheelRevs: Int?
        let wheelEvt: Int?     // 1/2048 s
        let crankRevs: Int?
        let crankEvt: Int?     // 1/1024 s
    }

    private var lastWheel: (revs: UInt32, time: UInt16)?
    private var lastCrank: (revs: UInt16, time: UInt16)?
    /// Discontinuity guard: trainers reset their cumulative counters (standby,
    /// firmware resync) without dropping the link, so one delta wraps to ~65k
    /// revs → 60000 rpm / 200000 km/h. Anything past these is a counter reset,
    /// not motion: skip the sample and re-seed from the new counters.
    static let maxRpm = 250
    static let maxKmh = 120.0
    private let wheelCircumferenceM: Double

    /// ponytail: fixed 700x25c circumference (2.105 m); make it a setting if speed reads off
    init(wheelCircumferenceM: Double = 2.105) {
        self.wheelCircumferenceM = wheelCircumferenceM
    }

    func reset() {
        lastWheel = nil
        lastCrank = nil
    }

    /// Returns nil for truncated packets (< 4 bytes).
    func parse(_ bytes: [UInt8], device: String?) -> Packet? {
        guard bytes.count >= 4 else { return nil }
        let flags = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let watts = Int(Int16(bitPattern: UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)))
        var balancePct: Double? = nil, torqueNm: Double? = nil
        var kmh: Double? = nil, rpm: Int? = nil
        var wheelRevs: Int? = nil, wheelEvt: Int? = nil, crankRevs: Int? = nil, crankEvt: Int? = nil
        var i = 4
        if flags & 0x0001 != 0, bytes.count >= i + 1 {   // pedal power balance, 0.5 %
            balancePct = Double(bytes[i]) / 2
            i += 1
        }
        if flags & 0x0004 != 0, bytes.count >= i + 2 {   // accumulated torque, 1/32 Nm
            torqueNm = Double(UInt16(bytes[i]) | (UInt16(bytes[i+1]) << 8)) / 32
            i += 2
        }
        if flags & 0x0010 != 0, bytes.count >= i + 6 {   // wheel revolution data
            let revs = UInt32(bytes[i]) | (UInt32(bytes[i+1]) << 8)
                     | (UInt32(bytes[i+2]) << 16) | (UInt32(bytes[i+3]) << 24)
            let t = UInt16(bytes[i+4]) | (UInt16(bytes[i+5]) << 8)   // 1/2048 s
            if let last = lastWheel {
                if t == last.time {
                    kmh = 0   // wheel stopped: no new event
                } else {
                    let dt = Double(t &- last.time) / 2048.0
                    kmh = Double(revs &- last.revs) * wheelCircumferenceM / dt * 3.6
                    if kmh! > Self.maxKmh { kmh = nil }   // counter reset
                }
            }
            lastWheel = (revs, t)
            wheelRevs = Int(revs); wheelEvt = Int(t)
            i += 6
        }
        if flags & 0x0020 != 0, bytes.count >= i + 4 {   // crank revolution data
            let revs = UInt16(bytes[i]) | (UInt16(bytes[i+1]) << 8)
            let t = UInt16(bytes[i+2]) | (UInt16(bytes[i+3]) << 8)   // 1/1024 s
            if let last = lastCrank {
                if t == last.time {
                    rpm = 0   // coasting: no new crank event
                } else {
                    let dt = Double(t &- last.time) / 1024.0
                    rpm = Int((Double(revs &- last.revs) / dt * 60).rounded())
                    if rpm! > Self.maxRpm { rpm = nil }   // counter reset
                }
            }
            lastCrank = (revs, t)
            crankRevs = Int(revs); crankEvt = Int(t)
        }
        return Packet(device: device, watts: watts, balancePct: balancePct, torqueNm: torqueNm,
                      kmh: kmh, rpm: rpm,
                      wheelRevs: wheelRevs, wheelEvt: wheelEvt,
                      crankRevs: crankRevs, crankEvt: crankEvt)
    }
}

extension CyclingPowerParser.Packet {
    /// Log-dict for one packet ("src": "pwr"), matching the historical JSONL shape.
    var logFields: [String: Any] {
        var ev: [String: Any] = ["src": "pwr", "watts": watts]
        if let n = device { ev["device"] = n }
        if let b = balancePct { ev["balance_pct"] = b }
        if let t = torqueNm { ev["torque_nm"] = t }
        if let w = wheelRevs { ev["wheel_revs"] = w }
        if let w = wheelEvt { ev["wheel_evt"] = w }
        if let c = crankRevs { ev["crank_revs"] = c }
        if let c = crankEvt { ev["crank_evt"] = c }
        if let s = kmh { ev["kmh"] = s }
        if let c = rpm { ev["rpm"] = c }
        return ev
    }

    /// The UI-facing reading (raw counters are logging-only).
    var reading: PowerReading {
        PowerReading(device: device, watts: watts, cadence: rpm,
                     kmh: kmh, balancePct: balancePct, torqueNm: torqueNm)
    }
}
