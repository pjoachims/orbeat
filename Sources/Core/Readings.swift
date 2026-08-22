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

/// One power/erg telemetry sample from any equipment source — bike trainer,
/// crank power meter, rower (RowErg), etc. Decoders in Components/Ergs all
/// produce this, whatever transport they speak.
struct PowerReading {
    let device: String?
    let watts: Int
    /// Cadence: crank RPM on a bike, stroke rate SPM on a rower. nil when the
    /// source doesn't report it.
    let cadence: Int?
    /// Ground/virtual speed where the source has a wheel or flywheel model;
    /// rowers report pace instead (ponytail) so usually nil there.
    let kmh: Double?
    let balancePct: Double?
    let torqueNm: Double?
}

/// Any sink for structured diagnostics. The BLE component logs every raw
/// packet and link event through this; the macOS Recorder implements it as a
/// JSONL file. Injected, so components never depend on a concrete logger.
protocol LogWriting: AnyObject {
    func log(_ fields: [String: Any])
}
