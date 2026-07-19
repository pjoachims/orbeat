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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let hr = HeartRate()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var floatingPanel: NSPanel?
    private var bpmObserver: AnyObject?
    private var ble: BLEManager?

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
            rootView: HeartCard(hr: hr, compact: true).padding(2))

        // Refresh the menu-bar title whenever any displayed metric ticks.
        bpmObserver = hr.$bpm.combineLatest(hr.$watts, hr.$cadence, hr.$speedKmh)
            .combineLatest(hr.$fresh)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusTitle() }
            } as AnyObject

        if CommandLine.arguments.contains("--float") { toggleFloating() }

        // Start scanning for a standard BLE heart-rate device (incl. a Fitbit
        // in workout "broadcast heart rate" mode). Falls back to the simulator.
        ble = BLEManager(model: hr)
    }

    private func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let over = hr.overThreshold
        let heartColor = over ? NSColor.white : NSColor(red: 1.0, green: 0.22, blue: 0.37, alpha: 1)
        let glyphAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: over ? NSColor.white : NSColor.labelColor]
        var segs: [(glyph: String, value: String, color: NSColor?)] = []
        if hr.barMetrics.contains("heart") { segs.append(("♥ ", hr.bpmText, heartColor)) }
        if hr.barMetrics.contains("power") {
            segs.append(("⚡", hr.displayWatts.map { "\($0)" } ?? "––", nil))
        }
        if hr.barMetrics.contains("rpm") {
            segs.append(("⟳ ", hr.displayCadence.map { "\($0)" } ?? "––", nil))
        }
        if hr.barMetrics.contains("speed") {
            segs.append(("≫ ", hr.displaySpeedKmh.map { String(format: "%.1f", $0) } ?? "––", nil))
        }
        if segs.isEmpty { segs = [("♥ ", hr.bpmText, heartColor)] }   // never a blank bar
        let s = NSMutableAttributedString()
        for (idx, seg) in segs.enumerated() {
            if idx > 0 { s.append(NSAttributedString(string: "  ", attributes: valueAttrs)) }
            var ga = glyphAttrs
            if let c = seg.color { ga[.foregroundColor] = c }
            s.append(NSAttributedString(string: seg.glyph, attributes: ga))
            s.append(NSAttributedString(string: seg.value, attributes: valueAttrs))
        }
        button.attributedTitle = s
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.backgroundColor = over ? NSColor.systemRed.cgColor : nil
        updateWarningHUD()
    }

    private var warningPanel: NSPanel?
    private func updateWarningHUD() {
        if hr.overThreshold {
            guard warningPanel == nil, let screen = NSScreen.main else { return }
            let host = NSHostingController(rootView: WarningHUD(hr: hr))
            let panel = NSPanel(contentRect: .zero,
                                styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.contentViewController = host
            panel.setContentSize(host.view.fittingSize)
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - 8))
            panel.orderFrontRegardless()
            warningPanel = panel
        } else {
            warningPanel?.close()
            warningPanel = nil
        }
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let src = NSMenuItem(title: "Source: \(hr.sourceName)", action: nil, keyEquivalent: "")
        src.isEnabled = false
        menu.addItem(src)
        let status = NSMenuItem(title: hr.bleStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let floatItem = NSMenuItem(title: floatingPanel == nil ? "Show Floating Widget" : "Hide Floating Widget",
                                   action: #selector(toggleFloating), keyEquivalent: "f")
        floatItem.target = self
        menu.addItem(floatItem)
        let equipItem = NSMenuItem(title: "Connect Equipment", action: nil, keyEquivalent: "")
        let equipSub = NSMenu()
        let devices = ble?.discovered ?? []
        if devices.isEmpty {
            let none = NSMenuItem(title: "Scanning… no devices yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            equipSub.addItem(none)
        }
        for (i, d) in devices.enumerated() {
            let item = NSMenuItem(title: "\(d.name) — \(d.isPower ? "Power" : "Heart Rate")",
                                  action: #selector(connectEquipment(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = (ble?.isConnected(d) ?? false) ? .on : .off
            equipSub.addItem(item)
        }
        let knownDevices = devices.enumerated().filter { ble?.isKnown($0.element) ?? false }
        if !knownDevices.isEmpty {
            equipSub.addItem(.separator())
            for (i, d) in knownDevices {
                let item = NSMenuItem(title: "Forget \(d.name)",
                                      action: #selector(forgetEquipment(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i
                equipSub.addItem(item)
            }
        }
        equipItem.submenu = equipSub
        menu.addItem(equipItem)
        let shareItem = NSMenuItem(title: "Share Sensors via Bluetooth",
                                   action: #selector(toggleRebroadcast), keyEquivalent: "")
        shareItem.target = self
        shareItem.state = (ble?.rebroadcaster.enabled ?? false) ? .on : .off
        menu.addItem(shareItem)
        let barItem = NSMenuItem(title: "Menu Bar Shows", action: nil, keyEquivalent: "")
        let barSub = NSMenu()
        for (title, key) in [("Heart Rate", "heart"), ("Power", "power"),
                             ("Cadence", "rpm"), ("Speed", "speed")] {
            let item = NSMenuItem(title: title, action: #selector(toggleBarMetric(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = hr.barMetrics.contains(key) ? .on : .off
            barSub.addItem(item)
        }
        barItem.submenu = barSub
        menu.addItem(barItem)
        let thresholdItem = NSMenuItem(title: "Alert Threshold", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let presets = [0, 100, 110, 120, 130, 140, 150, 160, 170, 180]
        for v in presets {
            let item = NSMenuItem(title: v == 0 ? "Off" : "\(v) BPM",
                                  action: #selector(setThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.tag = v
            item.state = hr.threshold == v ? .on : .off
            sub.addItem(item)
        }
        let isCustom = !presets.contains(hr.threshold)
        let custom = NSMenuItem(title: isCustom ? "Custom (\(hr.threshold) BPM)…" : "Custom…",
                                action: #selector(customThreshold), keyEquivalent: "")
        custom.target = self
        custom.state = isCustom ? .on : .off
        sub.addItem(custom)
        thresholdItem.submenu = sub
        menu.addItem(thresholdItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Orbeat", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // detach so left-click keeps opening the popover
    }

    @objc private func toggleBarMetric(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        if hr.barMetrics.contains(key) { hr.barMetrics.remove(key) }
        else { hr.barMetrics.insert(key) }
        updateStatusTitle()
    }

    @objc private func toggleRebroadcast() {
        ble?.rebroadcaster.enabled.toggle()
    }

    @objc private func connectEquipment(_ sender: NSMenuItem) {
        guard let ble, sender.tag < ble.discovered.count else { return }
        ble.connect(ble.discovered[sender.tag])
    }

    @objc private func forgetEquipment(_ sender: NSMenuItem) {
        guard let ble, sender.tag < ble.discovered.count else { return }
        ble.forget(ble.discovered[sender.tag])
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        hr.threshold = sender.tag
        updateStatusTitle()
    }

    @objc private func customThreshold() {
        let alert = NSAlert()
        alert.messageText = "Alert Threshold"
        alert.informativeText = "Warn when BPM reaches this value."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
        let fmt = NumberFormatter()
        fmt.allowsFloats = false
        fmt.minimum = 1
        fmt.maximum = 250
        field.formatter = fmt
        if hr.threshold > 0 { field.integerValue = hr.threshold }
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, field.integerValue > 0 {
            hr.threshold = field.integerValue
            updateStatusTitle()
        }
    }

    @objc private func toggleFloating() {
        if let panel = floatingPanel {
            panel.close()
            floatingPanel = nil
            return
        }
        let host = NSHostingController(rootView:
            HeartCard(hr: hr, compact: false)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 22)))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 288, height: 360),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentViewController = host
        panel.center()
        panel.orderFrontRegardless()
        floatingPanel = panel
    }
}
