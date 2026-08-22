import CoreBluetooth

/// Decodes Zwift Ride / Play handlebar button frames (see ZwiftButtonFrame).
/// Pure decode + rising-edge detection: no transport. Feed every notification
/// to `handle`.
final class ZwiftRideController {
    static let service   = CBUUID(string: "00000001-19CA-4651-86E5-FA29DCDD09D1")
    static let async     = CBUUID(string: "00000002-19CA-4651-86E5-FA29DCDD09D1")  // notify
    static let syncRx    = CBUUID(string: "00000003-19CA-4651-86E5-FA29DCDD09D1")  // write (RideOn)
    static let syncTx    = CBUUID(string: "00000004-19CA-4651-86E5-FA29DCDD09D1")  // notify
    static let unknown6  = CBUUID(string: "00000006-19CA-4651-86E5-FA29DCDD09D1")  // notify?
    /// "RideOn" wakes the button stream. Plaintext — no key exchange for this family.
    static let handshake = Data("RideOn".utf8)

    /// Notification characteristics that carry button frames.
    static func isButtonChar(_ uuid: CBUUID) -> Bool {
        uuid == async || uuid == syncTx || uuid == unknown6
    }

    /// Button bitmap masks (0x23 frame, field 1). Bit CLEAR = pressed.
    private static let buttons: [(name: String, mask: UInt32)] = [
        ("leftLeft", 0x00001), ("leftUp", 0x00002), ("leftRight", 0x00004), ("leftDown", 0x00008),
        ("rightA", 0x00010), ("rightB", 0x00020), ("rightY", 0x00040), ("rightZ", 0x00080),
        ("leftShiftUp", 0x00100), ("leftShiftDown", 0x00200), ("leftPowerUp", 0x00400),
        ("leftPower", 0x00800), ("rightShiftUp", 0x01000), ("rightShiftDown", 0x02000),
        ("rightPowerUp", 0x04000), ("rightPower", 0x08000), ("rightOnOff", 0x20000),
    ]

    private var lastMap: UInt32 = 0xFFFFFFFF

    /// Reset edge state; call on disconnect.
    func reset() { lastMap = 0xFFFFFFFF }

    /// Decode a notification. Returns a frame on a real state change, nil for
    /// non-button frames (wrong first byte) or unchanged repeats.
    func handle(_ bytes: [UInt8]) -> ZwiftButtonFrame? {
        guard let map = bitmap(bytes), map != lastMap else { return nil }
        let newly = Set(Self.buttons.map { $0.mask }
            .filter { (map & $0) == 0 && (lastMap & $0) != 0 })
        let pressed = Self.buttons.filter { map & $0.mask == 0 }.map { $0.name }
        lastMap = map
        return ZwiftButtonFrame(raw: bytes.map { String(format: "%02x", $0) }.joined(),
                               pressed: pressed, newlyPressed: newly)
    }

    /// Read a base-128 varint at `i`; returns (value, nextIndex) or nil if truncated.
    private func readVarint(_ b: [UInt8], _ i: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0, shift: UInt64 = 0, j = i
        while j < b.count {
            let byte = b[j]; j += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, j) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    /// Field-1 button bitmap from a 0x23 Zwift Ride frame (bit CLEAR = pressed).
    private func bitmap(_ bytes: [UInt8]) -> UInt32? {
        guard bytes.first == 0x23 else { return nil }
        var i = 1
        while i < bytes.count {
            guard let (tag, ni) = readVarint(bytes, i) else { return nil }
            i = ni
            let field = tag >> 3, wire = tag & 0x7
            if field == 1 && wire == 0 {
                guard let (v, _) = readVarint(bytes, i) else { return nil }
                return UInt32(truncatingIfNeeded: v)
            }
            switch wire {                       // skip other fields
            case 0: guard let (_, n) = readVarint(bytes, i) else { return nil }; i = n
            case 2: guard let (len, n) = readVarint(bytes, i) else { return nil }; i = n + Int(len)
            case 5: i += 4
            case 1: i += 8
            default: return nil
            }
        }
        return nil
    }
}
