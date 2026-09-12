import Foundation

/// Composition root shared by the Mac and iOS apps: the only place a
/// SensorEvent meets the model, and the only place handlebar inputs become
/// trainer commands. Keeps both apps behaving identically.
extension RideModel {
    func apply(_ event: SensorEvent, ble: BLEManager?) {
        switch event {
        case .status(let s):
            bleStatus = s
        case .heartLinkUp(let device):
            setLive(true, source: device)
        case .heartLinkDown:
            setLive(false, source: "Disconnected")
        case .powerLinkUp(let device):
            powerSource = device
        case .powerLinkDown:
            watts = nil
            cadence = nil
            speedKmh = nil
            powerSource = ""
        case .heartRate(let r):
            if r.bpm > 0 { ingest(r.bpm) }
        case .power(let p):
            watts = p.watts
            touch()   // power packets count as a sync too
            speedKmh = p.kmh
            cadence = p.cadence
        case .handlebar(let inputs):
            press(inputs, ble: ble)
        case .trainerReady:
            trainerControllable = true
            // Start in sim mode at the persisted grade (never resists hard on
            // connect until a paddle or the UI raises it).
            trainerMode = ble?.setTrainerMode(.sim(grade: grade))
        case .trainerLost:
            trainerControllable = false
            trainerMode = nil
        case .trainerMode(let m):
            // Trainer is the source of truth: follows changes made by the
            // other Orbeat app (or any other client) on the same KICKR.
            trainerMode = m
            if case .sim(let g) = m { grade = g }
        }
    }

    /// Handlebar inputs → trainer commands. Steps the CURRENT trainer mode:
    /// ERG ±10 W, resistance ±10 %, sim ±1 % grade.
    func press(_ inputs: [HandlebarInput], ble: BLEManager?) {
        guard var mode = trainerMode else { return }   // no trainer target yet
        for input in inputs {
            switch input {
            case .shiftUp: mode = mode.steppedUp
            case .shiftDown: mode = mode.steppedDown
            }
        }
        trainerMode = ble?.setTrainerMode(mode) ?? mode
        if case .sim(let g) = trainerMode { grade = g }   // persist sim grade
    }
}
