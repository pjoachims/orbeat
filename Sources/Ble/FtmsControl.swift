import CoreBluetooth

// Control point is command-out, not a telemetry driver.
/// Controls an FTMS trainer (Wahoo KICKR etc.) over the Fitness Machine Service.
/// Supports the three standard control targets via `TrainerMode`:
/// - ERG (`0x05` set target power) — trainer holds constant watts
/// - Resistance (`0x04` set target resistance levels)
/// - Sim grade (`0x11` set indoor bike simulation parameters)
///
/// ponytail: if a KICKR ignores FTMS, add the Wahoo proprietary path
/// (svc A026EE01, char A026E005: unlock 20 EE FC). Reading capability flags
/// (0x2AD2) before offering modes is also unimplemented — all three writes
/// are sent blindly and verified only on hardware that accepts them.
final class Trainer {
    static let service = CBUUID(string: "1826")
    static let controlPoint = CBUUID(string: "2AD9")

    private weak var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    /// Last applied (clamped) mode; nil while no trainer is attached or
    /// before the first target is pushed.
    private(set) var mode: TrainerMode?
    var isControllable: Bool { control != nil }

    /// Take control and start. Call on discovery; push targets via `set`.
    func attach(_ p: CBPeripheral, control ch: CBCharacteristic) {
        peripheral = p; control = ch
        p.writeValue(Data([0x00]), for: ch, type: .withResponse)   // request control
        p.writeValue(Data([0x07]), for: ch, type: .withResponse)   // start/resume
    }

    func detach() {
        peripheral = nil; control = nil; mode = nil
    }

    /// Push a control target. Returns the applied (clamped) value so the
    /// caller can keep its state in sync. Without attached hardware this
    /// still clamps and records — useful for tests and UI state.
    @discardableResult
    func set(_ requested: TrainerMode) -> TrainerMode {
        let m = requested.clamped
        guard let control, let p = peripheral else { return m }
        switch m {
        case .erg(let w):
            // 0x05 Set Target Power: sint16 LE, 1 W units.
            p.writeValue(i16Frame(0x05, w), for: control, type: .withResponse)
        case .resistance(let pct):
            // 0x04 Set Target Resistance Levels: sint16 LE. Unit is defined by
            // the trainer's 0x2AD6 range characteristic; we send 0.1 % steps,
            // which KICKR-class trainers accept. ponytail: read 0x2AD6 instead.
            p.writeValue(i16Frame(0x04, pct * 10), for: control, type: .withResponse)
        case .sim(let g):
            // 0x11 Set Indoor Bike Simulation Parameters:
            // wind(sint16, mm/s)=0, grade(sint16, 0.01%), crr(uint8)=0, cw(uint8)=0.
            let u = UInt16(bitPattern: Int16(g))
            p.writeValue(Data([0x11, 0x00, 0x00, UInt8(u & 0xFF), UInt8(u >> 8), 0x00, 0x00]),
                         for: control, type: .withResponse)
        }
        self.mode = m
        return m
    }

    /// opcode + sint16 LE payload
    private func i16Frame(_ opcode: UInt8, _ v: Int) -> Data {
        let u = UInt16(bitPattern: Int16(v))
        return Data([opcode, UInt8(u & 0xFF), UInt8(u >> 8)])
    }
}
