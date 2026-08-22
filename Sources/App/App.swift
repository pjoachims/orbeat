import SwiftUI
import AppKit
import Combine

@main
struct OrbeatApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
        app.run()
    }
}

/// Composition root: wires the BLE component's events onto the ride model and
/// owns all app policy. Menu lives in Menu.swift, windows/panels in Panels.swift.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = RideModel()
    let recorder = Recorder()
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var floatingPanel: NSPanel?
    var warningPanel: NSPanel?
    private var bpmObserver: AnyObject?
    var ble: BLEManager?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(statusClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusTitle()

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: HeartCard(model: model, compact: true).padding(2))

        // Refresh the menu-bar title whenever any displayed metric ticks.
        bpmObserver = model.$bpm.combineLatest(model.$watts, model.$cadence, model.$speedKmh)
            .combineLatest(model.$isFresh)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusTitle() }
            } as AnyObject

        if CommandLine.arguments.contains("--float") { toggleFloating() }

        // Start scanning for a standard BLE heart-rate device (incl. a Fitbit
        // in workout "broadcast heart rate" mode). Falls back to the simulator.
        let manager = BLEManager(log: recorder)
        manager.onEvent = { [weak self] in self?.handle($0) }
        ble = manager
    }

    // MARK: BLE event routing (the only place the component meets the model)

    private func handle(_ event: SensorEvent) {
        switch event {
        case .status(let s):
            model.bleStatus = s
        case .heartLinkUp(let device):
            model.setLive(true, source: device)
        case .heartLinkDown:
            model.setLive(false, source: "Disconnected")
        case .powerLinkUp(let device):
            model.powerSource = device
        case .powerLinkDown:
            model.watts = nil
            model.cadence = nil
            model.speedKmh = nil
            model.powerSource = ""
        case .heartRate(let r):
            if r.bpm > 0 { model.ingest(r.bpm) }
        case .power(let p):
            model.watts = p.watts
            model.touch()   // power packets count as a sync too
            model.speedKmh = p.kmh
            model.cadence = p.cadence
        case .handlebar(let inputs):
            applyRidePress(inputs)
        case .trainerReady:
            model.trainerControllable = true
            // Start in sim mode at the persisted grade (never resists hard on
            // connect until a paddle or the menu raises it).
            model.trainerMode = ble?.setTrainerMode(.sim(grade: model.grade))
        case .trainerLost:
            model.trainerControllable = false
            model.trainerMode = nil
        }
    }

    /// Handlebar inputs → trainer commands. Steps the CURRENT trainer mode:
    /// ERG ±10 W, resistance ±10 %, sim ±1 % grade.
    func applyRidePress(_ inputs: [HandlebarInput]) {
        guard var mode = model.trainerMode else { return }   // no trainer target yet
        for input in inputs {
            switch input {
            case .shiftUp: mode = mode.steppedUp
            case .shiftDown: mode = mode.steppedDown
            }
        }
        model.trainerMode = ble?.setTrainerMode(mode) ?? mode
        if case .sim(let g) = model.trainerMode { model.grade = g }   // persist sim grade
    }
}
