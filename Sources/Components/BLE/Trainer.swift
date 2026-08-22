import CoreBluetooth

/// Controls an FTMS trainer (Wahoo KICKR etc.) over the Fitness Machine Service.
/// Drives sim-grade (opcode 0x11): grade scales with speed like a real hill, so
/// slowing down can't spike resistance the way ERG target-power can.
/// ponytail: ERG mode (0x05 set-target-power) can bolt on here later — same
/// control point, add a mode + setTargetPower(w). If a KICKR ignores FTMS, add
/// the Wahoo proprietary path (svc A026EE01, char A026E005: unlock 20 EE FC).
final class Trainer {
    static let service = CBUUID(string: "1826")
    static let controlPoint = CBUUID(string: "2AD9")

    static let gradeStep = 100                // 0.01% units → 1.0% per press
    static let gradeRange = -500...1500       // -5% .. +15%

    private weak var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    var isControllable: Bool { control != nil }

    /// Take control and start. Call on discovery; push grade via setGrade.
    func attach(_ p: CBPeripheral, control ch: CBCharacteristic) {
        peripheral = p; control = ch
        p.writeValue(Data([0x00]), for: ch, type: .withResponse)   // request control
        p.writeValue(Data([0x07]), for: ch, type: .withResponse)   // start/resume
    }

    func detach() { peripheral = nil; control = nil }

    /// Set sim grade (0.01% units), clamped to gradeRange. Returns the applied value.
    @discardableResult
    func setGrade(_ grade: Int) -> Int {
        let g = min(Self.gradeRange.upperBound, max(Self.gradeRange.lowerBound, grade))
        guard let control, let p = peripheral else { return g }
        let u = UInt16(bitPattern: Int16(g))
        // 0x11 Set Indoor Bike Simulation Parameters:
        // wind(sint16, mm/s)=0, grade(sint16, 0.01%), crr(uint8)=0, cw(uint8)=0.
        p.writeValue(Data([0x11, 0x00, 0x00, UInt8(u & 0xFF), UInt8(u >> 8), 0x00, 0x00]),
                     for: control, type: .withResponse)
        return g
    }
}
