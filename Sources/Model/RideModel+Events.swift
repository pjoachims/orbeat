import Foundation

/// The only place SensorEvents and peer states meet the model. Local sensors
/// always win; the peer fills in whatever this device isn't connected to.
extension RideModel {
    func apply(_ event: SensorEvent, ble: BLEManager?) {
        let now = Date()
        switch event {
        case .status(let s):
            bleStatus = s
        case .heartLinkUp(let device):
            directHRSource = device
            setLive(true, source: device)
        case .heartLinkDown:
            directBPM = nil
            directBPMAt = .distantPast
            setLive(false, source: "Disconnected")
        case .powerLinkUp(let device):
            directPowerSource = device
            powerSource = device
        case .powerLinkDown:
            directPower = nil
            directPowerAt = .distantPast
            watts = nil
            cadence = nil
            speedKmh = nil
            powerSource = ""
        case .heartRate(let r):
            guard r.bpm > 0 else { return }
            directBPM = r.bpm
            directBPMAt = now
            if !directHRSource.isEmpty { sourceName = directHRSource }
            ingest(r.bpm)
        case .power(let p):
            directPower = p
            directPowerAt = now
            powerSource = directPowerSource
            showPower(p.watts, p.cadence, p.kmh)
        case .handlebar:
            break   // routed by AppCore: the trainer may live on the peer
        case .trainerReady:
            localTrainer = true
            trainerControllable = true
            // Start in sim mode at the persisted grade (never resists hard on
            // connect until a paddle or the UI raises it).
            trainerMode = ble?.setTrainerMode(.sim(grade: grade))
        case .trainerLost:
            localTrainer = false
            trainerControllable = peer?.trainer != nil
            trainerMode = peer?.trainer
        case .trainerMode(let m):
            // Trainer is the source of truth: follows changes made by any
            // other client on the same trainer.
            trainerMode = m
            if case .sim(let g) = m { grade = g }
        }
    }

    /// Peer state arrived (nil = link dropped).
    func apply(peer s: PeerState?) {
        peer = s
        let now = Date()
        let label = PeerLink.peerLabel
        if let b = s?.bpm, now.timeIntervalSince(directBPMAt) > Self.directWindow {
            sourceName = "\(s?.hrSource ?? "Heart rate") · via \(label)"
            setLive(true, source: sourceName)
            ingest(b)
        }
        if let s, let w = s.watts, now.timeIntervalSince(directPowerAt) > Self.directWindow {
            powerSource = "\(s.powerSource ?? "Power") · via \(label)"
            showPower(w, s.cadence, s.kmh)
        }
        if !localTrainer {
            trainerControllable = s?.trainer != nil
            trainerMode = s?.trainer
            if case .sim(let g) = s?.trainer { grade = g }
        }
    }

    /// What this device publishes to its peer: direct readings only.
    func directState(recordingSince: Date?) -> PeerState {
        let now = Date()
        let hr = now.timeIntervalSince(directBPMAt) < Self.directWindow
        let pw = now.timeIntervalSince(directPowerAt) < Self.directWindow ? directPower : nil
        return PeerState(bpm: hr ? directBPM : nil, hrSource: hr ? directHRSource : nil,
                         watts: pw?.watts, cadence: pw?.cadence, kmh: pw?.kmh,
                         powerSource: pw != nil ? directPowerSource : nil,
                         trainer: localTrainer ? trainerMode : nil,
                         recordingSince: recordingSince)
    }

    /// Step the LOCAL trainer's current mode: ERG ±10 W, resistance ±10 %, sim ±1 %.
    func press(_ inputs: [HandlebarInput], ble: BLEManager?) {
        guard var mode = trainerMode else { return }   // no trainer target yet
        for input in inputs {
            mode = input == .shiftUp ? mode.steppedUp : mode.steppedDown
        }
        setTrainer(mode, ble: ble)
    }

    /// Push a target to the LOCAL trainer.
    func setTrainer(_ mode: TrainerMode, ble: BLEManager?) {
        trainerMode = ble?.setTrainerMode(mode) ?? mode.clamped
        if case .sim(let g) = trainerMode { grade = g }   // persist sim grade
    }

    private func showPower(_ w: Int, _ c: Int?, _ kmh: Double?) {
        watts = w
        cadence = c
        speedKmh = kmh
        touch()   // power packets count as a sync too
    }
}
