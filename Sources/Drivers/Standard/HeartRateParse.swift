import Foundation

/// Parses standard BLE Heart Rate Measurement packets (0x2A37). Stateless.
enum HeartRateParser {
    /// Spec: byte0 flags; bit0 = value format (0 = UInt8, 1 = UInt16 LE),
    /// bit1/2 = sensor contact, bit3 = energy expended, bit4 = RR intervals.
    /// Returns nil for truncated packets.
    static func parse(_ bytes: [UInt8], device: String?) -> HeartRateReading? {
        guard let flags = bytes.first else { return nil }
        let bpm: Int
        var i: Int
        if (bytes.count >= 2) && (flags & 0x01) == 0 {
            bpm = Int(bytes[1]); i = 2
        } else if bytes.count >= 3 {
            bpm = Int(bytes[1]) | (Int(bytes[2]) << 8); i = 3
        } else {
            return nil
        }
        var contact: Bool? = nil, kj: Int? = nil, rrMs: [Int]? = nil
        if flags & 0x04 != 0 { contact = (flags & 0x02) != 0 }
        if flags & 0x08 != 0, bytes.count >= i + 2 {   // energy expended, kJ
            kj = Int(bytes[i]) | (Int(bytes[i+1]) << 8)
            i += 2
        }
        if flags & 0x10 != 0 {   // RR intervals, u16 each, 1/1024 s
            var rr: [Int] = []
            while bytes.count >= i + 2 {
                let v = Int(bytes[i]) | (Int(bytes[i+1]) << 8)
                rr.append(Int((Double(v) / 1024.0 * 1000).rounded()))   // → ms
                i += 2
            }
            if !rr.isEmpty { rrMs = rr }
        }
        return HeartRateReading(device: device, bpm: bpm,
                                contact: contact, kj: kj, rrMs: rrMs)
    }

    /// Log-dict for one reading ("src": "hr"), matching the historical JSONL shape.
    static func logFields(_ r: HeartRateReading) -> [String: Any] {
        var ev: [String: Any] = ["src": "hr", "bpm": r.bpm]
        if let n = r.device { ev["device"] = n }
        if let c = r.contact { ev["contact"] = c }
        if let k = r.kj { ev["kj"] = k }
        if let rr = r.rrMs { ev["rr_ms"] = rr }
        return ev
    }
}
