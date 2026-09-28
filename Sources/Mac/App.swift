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
        let host = NSHostingController(
            rootView: HeartCard(model: model, compact: true,
                                onStep: { [weak self] in self?.applyRidePress([$0]) }).padding(2))
        host.sizingOptions = .preferredContentSize   // popover tracks the card's size
        popover.contentViewController = host

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
        manager.onEvent = { [weak self] in self?.model.apply($0, ble: self?.ble) }
        ble = manager
    }

    func applyRidePress(_ inputs: [HandlebarInput]) { model.press(inputs, ble: ble) }
}
