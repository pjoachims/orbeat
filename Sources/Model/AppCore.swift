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
    private var lastPush = Date.distantPast

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
            if up { pushState(force: true) } else { model.apply(peer: nil) }
        }
        self.peer = peer
        #endif
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

    /// Session running here or on the peer.
    var recordingSince: Date? { store.active?.start ?? model.peer?.recordingSince }

    /// Records on this device (sessions record where they are started).
    func startSession() {
        guard recordingSince == nil else { return }
        store.start()
        pushState(force: true)
    }

    func stopSession() {
        if store.active != nil { store.stop(); pushState(force: true) }
        else if model.peer?.recordingSince != nil { peer?.send(.command(.stopSession)) }
    }

    // MARK: Plumbing

    private func handle(_ event: SensorEvent) {
        if case .handlebar(let inputs) = event { inputs.forEach(step) }
        else { model.apply(event, ble: ble) }
        tick()
    }

    private func handle(_ message: PeerMessage) {
        switch message {
        case .state(let s):
            model.apply(peer: s)
            store.tick(model)
        case .command(.step(let i)):
            if model.localTrainer { step(i) }
        case .command(.setTrainer(let m)):
            if model.localTrainer { setTrainer(m) }
        case .command(.stopSession):
            if store.active != nil { stopSession() }
        }
    }

    private func tick() {
        store.tick(model)
        pushState()
    }

    private func pushState(force: Bool = false) {
        guard let peer, peer.connected, force || Date().timeIntervalSince(lastPush) >= 0.9 else { return }
        lastPush = Date()
        peer.send(.state(model.directState(recordingSince: store.active?.start)))
    }

    #if targetEnvironment(simulator)
    /// No Bluetooth in the simulator: fake a ride so every screen has data.
    private func simulate() {
        model.setLive(true, source: "Simulated ride")
        model.localTrainer = true
        model.trainerControllable = true
        model.trainerMode = .sim(grade: model.grade)
        var bpm = 128.0, watts = 210.0
        Task { @MainActor [model] in
            while true {
                bpm = min(174, max(96, bpm + .random(in: -4...5)))
                watts = min(340, max(140, watts + .random(in: -14...14)))
                model.ingest(Int(bpm))
                model.watts = Int(watts)
                model.cadence = Int.random(in: 84...96)
                model.speedKmh = watts / 6.4
                try? await Task.sleep(for: .seconds(1.1))
            }
        }
    }
    #endif
}
