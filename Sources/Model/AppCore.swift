import Foundation
import Combine

/// Composition root shared by the Mac and iOS apps: sensors, peer link,
/// model, sessions. The UI calls the intent methods below; each one routes to
/// whichever device owns the trainer or the running session.
final class AppCore: ObservableObject {
    let model = RideModel()
    let store = SessionStore()
    let recorder = Recorder()
    private(set) var ble: BLEManager?
    private(set) var peer: PeerLink?
    private var timer: AnyCancellable?
    private var settings: AnyCancellable?
    private var lastPush = Date.distantPast
    private var routeAt: Date?
    private var lastGradeAt = Date.distantPast

    init() {
        #if targetEnvironment(simulator)
        simulate()
        #else
        let ble = BLEManager(log: recorder)
        ble.onEvent = { [weak self] in self?.handle($0) }
        self.ble = ble
        #if os(macOS)
        let peer = PeerLink(proxy: ble.proxy)
        #else
        let peer = PeerLink()
        peer.onLog = { [recorder] in recorder.log($0) }
        #endif
        peer.onMessage = { [weak self] in self?.handle($0) }
        peer.onConnected = { [weak self] up in
            guard let self else { return }
            recorder.log(["src": "peer", "ev": up ? "linkUp" : "linkDown"])
            model.peerConnected = up
            if up { pushState(force: true) } else { applyPeer(nil) }
        }
        self.peer = peer
        #endif
        syncSettings()
        // Mac: the heartbeat. iOS: suspended in background, where sensor
        // events (which wake the app) drive sampling and pushes instead.
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    // MARK: Intents (UI, menus, paddles)

    func step(_ input: HandlebarInput) {
        if model.localTrainer { model.press([input], ble: ble); pushState(force: true) }
        else if model.peer?.trainer != nil { peer?.send(.command(.step(input))) }
    }

    func setTrainer(_ mode: TrainerMode) {
        if model.localTrainer { model.setTrainer(mode, ble: ble); pushState(force: true) }
        else if model.peer?.trainer != nil { peer?.send(.command(.setTrainer(mode))) }
    }

    /// New rider settings: kept here, and applied where the trainer is — the
    /// owner re-sends the sim target so the trainer feels it now.
    func setRider(_ r: Rider) {
        let r = r.clamped
        model.rider = r
        if model.localTrainer, case .sim? = model.trainerMode { setTrainer(model.trainerMode!) }
        else if model.peer?.trainer != nil { peer?.send(.command(.setRider(r))) }
    }

    /// Terrain grade for sim, keeping the gear where the trainer is. No-op
    /// outside sim: a route never switches the trainer out of ERG.
    func setGrade(_ g: Int) {
        if model.localTrainer, case .sim(_, let gear)? = model.trainerMode {
            setTrainer(.sim(grade: g, gear: gear).clamped)
        } else if !model.localTrainer, model.peer?.trainer != nil { peer?.send(.command(.setGrade(g))) }
    }

    /// Start riding a route from its beginning (nil = stop). Switches the
    /// trainer to sim: the route only drives sim.
    func ride(_ r: Route?) {
        model.route = r
        model.routeMeters = 0
        routeAt = nil
        lastGradeAt = .distantPast
        if r == nil { setGrade(0) }   // stopped: flat, like finishing
        else if model.trainerControllable, !TrainerMode.sim(grade: 0).sameKind(as: model.trainerMode) {
            setTrainer(.sim(grade: 0))
        }
    }

    /// A GPX file (Files, share sheet, Open panel) or orbeat://ride?gpx=<https URL>.
    func open(_ url: URL) {
        if url.isFileURL {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            load(try? Data(contentsOf: url), from: url)
        } else if url.scheme == "orbeat", url.host == "ride",
                  let s = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                      .queryItems?.first(where: { $0.name == "gpx" })?.value,
                  let remote = URL(string: s), remote.scheme == "https" {
            URLSession.shared.dataTask(with: remote) { [weak self] data, response, _ in
                let ok = (response as? HTTPURLResponse)?.statusCode == 200 && (data?.count ?? 0) <= 20_000_000
                DispatchQueue.main.async { self?.load(ok ? data : nil, from: remote) }
            }.resume()
        } else {
            model.routeError = "Orbeat can't open \(url.absoluteString)."
        }
    }

    private func load(_ data: Data?, from url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        guard let r = data.flatMap({ Route.gpx($0, name: name) }) else {
            recorder.log(["src": "route", "ev": "rejected", "url": url.absoluteString, "bytes": data?.count ?? -1])
            model.routeError = data == nil ? "Couldn't download or read \(url.lastPathComponent)."
                                           : "\(url.lastPathComponent) has no elevation to ride."
            return
        }
        recorder.log(["src": "route", "ev": "loaded", "name": r.name, "km": r.length / 1000, "points": r.dist.count])
        ride(r)
    }

    /// Clock of the session running here or on the peer.
    var recording: SessionClock? { store.clock ?? model.peer?.recording }

    /// Records on this device (sessions record where they are started).
    func startSession() {
        guard recording == nil else { return }
        store.start()
        pushState(force: true)
    }

    /// Reopen a saved session here; it records on as the same session.
    func continueSession(_ s: Session) {
        guard recording == nil else { return }
        store.resume(s)
        pushState(force: true)
    }

    func setPaused(_ paused: Bool) {
        if store.active != nil { store.setPaused(paused); pushState(force: true) }
        else if model.peer?.recording != nil { peer?.send(.command(.pauseSession(paused))) }
    }

    func stopSession() {
        if store.active != nil { store.stop(); pushState(force: true) }
        else if model.peer?.recording != nil { peer?.send(.command(.stopSession)) }
    }

    // MARK: Plumbing

    /// Threshold via iCloud KVS: cloud value wins at launch, then follow changes.
    private func syncSettings() {
        guard SessionStore.cloudSync else { return }
        let kvs = NSUbiquitousKeyValueStore.default
        let adopt = { [model] in
            if kvs.object(forKey: "threshold") != nil { model.threshold = Int(kvs.longLong(forKey: "threshold")) }
        }
        settings = NotificationCenter.default
            .publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kvs)
            .receive(on: DispatchQueue.main)
            .sink { _ in adopt() }
        kvs.synchronize()
        adopt()
    }

    private func handle(_ event: SensorEvent) {
        if case .handlebar(let inputs) = event { inputs.forEach(step) }
        else { model.apply(event, ble: ble) }
        tick()
    }

    private func handle(_ message: PeerMessage) {
        switch message {
        case .state(let s):
            applyPeer(s)
            store.tick(model)
        case .command(.step(let i)):
            if model.localTrainer { step(i) }
        case .command(.setTrainer(let m)):
            if model.localTrainer { setTrainer(m) }
        case .command(.setRider(let r)):
            setRider(r)
        case .command(.setGrade(let g)):
            if model.localTrainer, model.route == nil { setGrade(g) }   // own route wins: no flapping
        case .command(.stopSession):
            if store.active != nil { stopSession() }
        case .command(.pauseSession(let p)):
            if store.active != nil { setPaused(p) }
        }
    }

    /// Peer state in; if that hands us the trainer, hold its last target.
    private func applyPeer(_ s: PeerState?) {
        let drove = model.localTrainer
        model.apply(peer: s)
        if !drove, model.localTrainer, let m = model.trainerMode { setTrainer(m) }
    }

    private func tick() {
        store.tick(model)
        followRoute()
        pushState()
    }

    /// Route mode, on the device that loaded the route (the trainer may be on
    /// the peer): advance at road-model speed, send the grade when it changes
    /// by ≥ 0.1 %, at most once a second. Paused outside sim and while no
    /// fresh power arrives. Flat once finished.
    private func followRoute() {
        guard let route = model.route, case .sim(let g, _)? = model.trainerMode else { routeAt = nil; return }
        let now = Date()
        if let t = routeAt, let v = model.speedKmh, now.timeIntervalSince(model.powerAt) < RideModel.directWindow {
            model.routeMeters = min(route.length, model.routeMeters + v / 3.6 * min(now.timeIntervalSince(t), 5))
        }
        routeAt = now
        let target = model.routeMeters < route.length ? route.grade(at: model.routeMeters) : 0
        if abs(target - g) >= 10, now.timeIntervalSince(lastGradeAt) >= 1 {
            lastGradeAt = now
            setGrade(target)
        }
    }

    private func pushState(force: Bool = false) {
        guard let peer, peer.connected, force || Date().timeIntervalSince(lastPush) >= 0.9 else { return }
        lastPush = Date()
        peer.send(.state(model.directState(recording: store.clock)))
    }

    #if targetEnvironment(simulator)
    /// No Bluetooth in the simulator: fake a ride so every screen has data.
    private func simulate() {
        model.setLive(true, source: "Simulated ride")
        model.localTrainer = true
        model.trainerControllable = true
        model.trainerMode = .sim(grade: model.grade, gear: model.gear)
        var bpm = 128.0, watts = 210.0
        Task { @MainActor [model] in
            while true {
                bpm = min(174, max(96, bpm + .random(in: -4...5)))
                watts = min(340, max(140, watts + .random(in: -14...14)))
                model.ingest(Int(bpm))
                model.showPower(Int(watts), Int.random(in: 84...96))   // same road model as a real trainer
                try? await Task.sleep(for: .seconds(1.1))
            }
        }
    }
    #endif
}
