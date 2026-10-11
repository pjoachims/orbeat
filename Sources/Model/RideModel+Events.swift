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
            trainerAttached = true
            updateOwner()
            guard localTrainer else { return }   // the peer drives it; we mirror
            trainerControllable = true
            // The peer may already ride this trainer: keep its target. Else
            // start in sim at the persisted grade (never resists hard on
            // connect) — after a grace period, so a peer link still coming
            // up can report its target first (adopted in apply(peer:)).
            trainerAttach += 1
            let attach = trainerAttach
            trainerMode = peer?.trainer
            guard trainerMode == nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak ble] in
                guard let self, attach == trainerAttach, localTrainer, trainerMode == nil else { return }
                trainerMode = ble?.setTrainerMode(.sim(grade: grade, gear: gear), rider: rider)
            }
        case .trainerLost:
            trainerAttached = false
            localTrainer = false
            trainerControllable = peer?.trainer != nil
            trainerMode = peer?.trainer
        case .trainerMode(let m):
            guard localTrainer else { return }   // mirroring the peer: its state is the truth
            // Trainer is the source of truth for ERG/resistance: follows changes
            // made by any other client on the same trainer. A sim frame only
            // carries the grade the trainer got — terrain, difficulty and gear
            // can't be split back out of it (and it may be our own late echo) —
            // so sim follows the kind only and keeps our terrain + gear.
            if case .sim = m {
                if case .sim? = trainerMode { return }
                trainerMode = .sim(grade: grade, gear: gear)
                return
            }
            trainerMode = m
            remember(m)
        }
    }

    /// Peer state arrived (nil = link dropped).
    func apply(peer s: PeerState?) {
        peer = s
        updateOwner()
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
        if !localTrainer, let r = s?.rider?.clamped, r != rider { rider = r }   // owner's settings win
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

    /// Who drives the trainer. Attached here alone: us. iPhone and Mac both on
    /// it: the iPhone (it's on the bike), and the Mac mirrors it like any
    /// non-owner — two drivers would each keep their own gear and grade.
    /// Re-evaluated on attach and on every peer state; the Mac takes over
    /// when the phone stops driving (AppCore re-sends the last target).
    func updateOwner() {
        let own = trainerAttached && !(Self.yieldsSharedTrainer && peer?.trainer != nil)
        guard own != localTrainer else { return }
        localTrainer = own
        trainerControllable = own || peer?.trainer != nil
        if !own { trainerMode = peer?.trainer }
    }
    #if os(macOS)
    static let yieldsSharedTrainer = true
    #else
    static let yieldsSharedTrainer = false
    #endif

    /// What this device publishes to its peer: direct readings only.
    func directState(recording: SessionClock?) -> PeerState {
        let now = Date()
        let hr = now.timeIntervalSince(directBPMAt) < Self.directWindow
        let pw = now.timeIntervalSince(directPowerAt) < Self.directWindow ? directPower : nil
        var s = PeerState(bpm: hr ? directBPM : nil, hrSource: hr ? directHRSource : nil,
                          watts: pw?.watts, cadence: pw?.cadence, kmh: pw?.kmh,
                          powerSource: pw != nil ? directPowerSource : nil,
                          trainer: localTrainer ? trainerMode : nil)
        s.recording = recording
        s.rider = localTrainer ? rider : nil
        return s
    }

    /// Step the LOCAL trainer's current mode: ERG ±5 W, resistance ±10 %, sim ±1 gear.
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
        let m = mode.sameKind(as: trainerMode) ? mode : mode.resumed(ergWatts: ergWatts, grade: grade, gear: gear)
        trainerMode = ble?.setTrainerMode(m, rider: rider) ?? m.clamped
        remember(trainerMode)
    }

    /// Persist the latest target per kind, from wherever it was set.
    private func remember(_ m: TrainerMode?) {
        switch m {
        case .erg(let w)?: ergWatts = w
        case .sim(let g, let gr)?: grade = g; gear = gr
        default: break
        }
    }

    func showPower(_ w: Int, _ c: Int?) {
        watts = w
        cadence = c
        // Road-model speed, not the trainer's wheel speed (bogus in ERG).
        if case .sim(let g, _) = trainerMode { speedKmh = RoadSpeed.kmh(watts: w, gradePercent: Double(g) / 100, massKg: rider.massKg) }
        else { speedKmh = RoadSpeed.kmh(watts: w, massKg: rider.massKg) }
        powerAt = Date()
        touch()   // power packets count as a sync too
    }
}
