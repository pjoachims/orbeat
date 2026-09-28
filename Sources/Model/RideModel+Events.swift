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
            showPower(p.watts, p.cadence)
        case .handlebar:
            break   // routed by AppCore: the trainer may live on the peer
        case .trainerReady:
            localTrainer = true
            trainerControllable = true
            // The peer may already ride this trainer: keep its target. Else
            // start in sim at the persisted grade (never resists hard on
            // connect) — after a grace period, so a peer link still coming
            // up can report its target first (adopted in apply(peer:)).
            trainerMode = peer?.trainer
            guard trainerMode == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak ble] in
                guard let self, localTrainer, trainerMode == nil else { return }
                trainerMode = ble?.setTrainerMode(.sim(grade: grade))
            }
        case .trainerLost:
            localTrainer = false
            trainerControllable = peer?.trainer != nil
            trainerMode = peer?.trainer
        case .trainerMode(let m):
            // Trainer is the source of truth: follows changes made by any
            // other client on the same trainer.
            trainerMode = m
            remember(m)
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
            showPower(w, s.cadence)
        }
        // Guarded: states arrive every second; unchanged writes would
        // re-render every view and hit UserDefaults each time.
        if !localTrainer, trainerMode != s?.trainer {
            trainerControllable = s?.trainer != nil
            trainerMode = s?.trainer
            remember(s?.trainer)
        } else if localTrainer, trainerMode == nil, let t = s?.trainer {
            trainerMode = t   // both on one trainer: adopt the peer's target, no write
            remember(t)
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

    /// Step the LOCAL trainer's current mode: ERG ±5 W, resistance ±10 %, sim ±0.5 %.
    func press(_ inputs: [HandlebarInput], ble: BLEManager?) {
        guard var mode = trainerMode else { return }   // no trainer target yet
        for input in inputs {
            mode = input == .shiftUp ? mode.steppedUp : mode.steppedDown
        }
        setTrainer(mode, ble: ble)
    }

    /// Push a target to the LOCAL trainer. A different kind (the picker)
    /// resumes that kind's last target.
    func setTrainer(_ mode: TrainerMode, ble: BLEManager?) {
        let m = mode.sameKind(as: trainerMode) ? mode : mode.resumed(ergWatts: ergWatts, grade: grade)
        trainerMode = ble?.setTrainerMode(m) ?? m.clamped
        remember(trainerMode)
    }

    /// Persist the latest target per kind, from wherever it was set.
    private func remember(_ m: TrainerMode?) {
        switch m {
        case .erg(let w)?: ergWatts = w
        case .sim(let g)?: grade = g
        default: break
        }
    }

    private func showPower(_ w: Int, _ c: Int?) {
        watts = w
        cadence = c
        // Road-model speed, not the trainer's wheel speed (bogus in ERG).
        if case .sim(let g) = trainerMode { speedKmh = RoadSpeed.kmh(watts: w, gradePercent: Double(g) / 100) }
        else { speedKmh = RoadSpeed.kmh(watts: w) }
        touch()   // power packets count as a sync too
    }
}
