import Foundation

/// A decoded heart-rate measurement (standard BLE 0x2A37 packet).
struct HeartRateReading {
    let device: String?
    let bpm: Int
    /// Sensor contact flag from the packet, if present.
    let contact: Bool?
    /// Energy expended (kJ), if present.
    let kj: Int?
    /// RR intervals in ms, if present.
    let rrMs: [Int]?
}

/// A decoded cycling-power measurement (standard BLE 0x2A63 packet) with
/// speed/cadence already derived from the wheel/crank revolution deltas.
struct PowerReading {
    let device: String?
    let watts: Int
    /// Pedal power balance (%), if present.
    let balancePct: Double?
    /// Accumulated torque (Nm), if present.
    let torqueNm: Double?
    let kmh: Double?
    let rpm: Int?
}

/// Any sink for structured diagnostics. The BLE component logs every raw
/// packet and link event through this; the macOS Recorder implements it as a
/// JSONL file. Injected, so components never depend on a concrete logger.
protocol LogWriting: AnyObject {
    func log(_ fields: [String: Any])
}

/// Neutral handlebar-controller input — what the rider did, regardless of
/// which brand of controller decoded it. Components translate their proprietary
/// button frames into these; app policy (e.g. grade stepping) consumes them.
enum HandlebarInput {
    case shiftUp
    case shiftDown
}

/// Everything the BLE component reports upward. The app layer maps these onto
/// its UI model and policies; the BLE component knows nothing about either.
enum BLEEvent {
    case status(String)                    // human-readable scan/link state
    case heartLinkUp(device: String)
    case heartLinkDown
    case powerLinkUp(device: String)
    case powerLinkDown
    case heartRate(HeartRateReading)
    case power(PowerReading)
    case handlebar([HandlebarInput])       // fresh paddle presses
    case trainerReady                      // FTMS control point discovered & claimed
    case trainerLost
}
