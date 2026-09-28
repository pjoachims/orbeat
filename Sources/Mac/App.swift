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

/// Mac shell around the shared AppCore: menu-bar item, popover, panels.
/// Menu lives in Menu.swift, windows/panels in Panels.swift.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var core: AppCore!
    var model: RideModel { core.model }
    var recorder: Recorder { core.recorder }
    var ble: BLEManager? { core.ble }
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var floatingPanel: NSPanel?
    var warningPanel: NSPanel?
    var sessionsWindow: NSWindow?
    private var bpmObserver: AnyObject?

    func applicationDidFinishLaunching(_ note: Notification) {
        core = AppCore()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(statusClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusTitle()

        popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(rootView: VStack(spacing: 0) {
            HeartCard(model: model, compact: true,
                      onStep: { [weak self] in self?.applyRidePress([$0]) }, onSet: core.setTrainer)
            SessionBar(core: core, store: core.store, model: model, compact: true)
                .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 272)
        .padding(2))
        host.sizingOptions = .preferredContentSize   // popover tracks the card's size
        popover.contentViewController = host

        // Refresh the menu-bar title whenever any displayed metric ticks.
        bpmObserver = model.$bpm.combineLatest(model.$watts, model.$cadence, model.$speedKmh)
            .combineLatest(model.$isFresh)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusTitle() }
            } as AnyObject

        if CommandLine.arguments.contains("--float") { toggleFloating() }
        if CommandLine.arguments.contains("--sessions") { showSessions() }
    }

    func applyRidePress(_ inputs: [HandlebarInput]) { inputs.forEach(core.step) }
}
