import Foundation

/// Parses FTMS Indoor Bike Data notifications (char 0x2AD2) into the shared
/// erg reading. This is the second power source beside the Cycling Power
/// Service — trainers that only speak FTMS (and future rower/RowErg decoders)
/// slot in here and produce the same Core type.
///
/// Stateless. Flag layout per Fitness Machine Service spec §4.9 (verified
/// against pycycling + real-device captures):
///   bit0 more-data (0 ⇒ inst. speed present), bit1 avg speed,
///   bit2 inst. cadence (u16 ×0.5 rpm), bit3 avg cadence, bit4 total distance
///   (u24 m), bit5 resistance (s16), bit6 inst. power (s16 W),
///   bit7 avg power; byte1: bit8 energy, bit9 heart rate, …
enum FtmsIndoorBikeParser {
    struct Packet {
        let device: String?
        /// nil when the source omits the instantaneous-power field.
        let watts: Int?
        let kmh: Double?
        let rpm: Int?

        var logFields: [String: Any] {
            var ev: [String: Any] = ["src": "pwr"]
            if let n = device { ev["device"] = n }
            if let w = watts { ev["watts"] = w }
            if let s = kmh { ev["kmh"] = s }
            if let c = rpm { ev["rpm"] = c }
            return ev
        }

        var reading: PowerReading? {
            guard let watts else { return nil }
            return PowerReading(device: device, watts: watts, cadence: rpm,
                                kmh: kmh, balancePct: nil, torqueNm: nil)
        }
    }

    /// Returns nil for truncated packets or packets without an instant-power
    /// field (nothing to feed the model).
    static func parse(_ bytes: [UInt8], device: String?) -> Packet? {
        guard bytes.count >= 2 else { return nil }
        let flags = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        var i = 2
        var kmh: Double? = nil, rpm: Int? = nil, watts: Int? = nil

        func u16(_ resolution: Double = 1) -> Double? {
            guard bytes.count >= i + 2 else { return nil }
            let v = Double(UInt16(bytes[i]) | (UInt16(bytes[i+1]) << 8))
            i += 2
            return v * resolution
        }

        if flags & 0x0001 == 0 {                    // instantaneous speed
            kmh = u16(0.01)
        }
        if flags & 0x0002 != 0 { _ = u16() }        // average speed — skip
        if flags & 0x0004 != 0 {                    // instantaneous cadence, 0.5 rpm
            rpm = u16(0.5).map { Int($0.rounded()) }
        }
        if flags & 0x0008 != 0 { _ = u16() }        // average cadence — skip
        if flags & 0x0010 != 0 {                    // total distance, u24 metres
            guard bytes.count >= i + 3 else { return nil }
            i += 3
        }
        if flags & 0x0020 != 0 { _ = u16() }        // resistance level — skip
        if flags & 0x0040 != 0 {                    // instantaneous power, s16 W
            guard bytes.count >= i + 2 else { return nil }
            watts = Int(Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i+1]) << 8)))
            i += 2
        }
        // average power, energy, HR, elapsed/remaining time: not consumed;
        // we stop here rather than walk every optional tail field.
        return Packet(device: device, watts: watts, kmh: kmh, rpm: rpm)
    }
}
