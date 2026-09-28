import AppKit

/// The right-click menu and all its item actions.
extension AppDelegate {
    @objc func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let src = NSMenuItem(title: "Source: \(model.sourceName)", action: nil, keyEquivalent: "")
        src.isEnabled = false
        menu.addItem(src)
        let status = NSMenuItem(title: model.bleStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let floatItem = NSMenuItem(title: floatingPanel == nil ? "Show Floating Widget" : "Hide Floating Widget",
                                   action: #selector(toggleFloating), keyEquivalent: "f")
        floatItem.target = self
        menu.addItem(floatItem)
        menu.addEquipmentSubmenu(from: ble, target: self)
        if model.trainerControllable {
            let mode = model.trainerMode
            let target = NSMenuItem(title: "Trainer — \(mode?.label ?? "ready")",
                                    action: nil, keyEquivalent: "")
            target.isEnabled = false
            menu.addItem(target)
            let harder = NSMenuItem(title: "Harder (\(mode?.stepLabel ?? "+1 %"))",
                                    action: #selector(harder), keyEquivalent: "")
            harder.target = self
            menu.addItem(harder)
            let easier = NSMenuItem(title: "Easier (\((mode?.stepLabel ?? "+1 %").replacingOccurrences(of: "+", with: "−"))",
                                    action: #selector(easier), keyEquivalent: "")
            easier.target = self
            menu.addItem(easier)
        }
        let shareItem = NSMenuItem(title: "Share Sensors via Bluetooth",
                                   action: #selector(toggleRebroadcast), keyEquivalent: "")
        shareItem.target = self
        shareItem.state = (ble?.proxy.enabled ?? false) ? .on : .off
        menu.addItem(shareItem)
        let logItem = NSMenuItem(title: "Log to DuckDB (JSONL)",
                                 action: #selector(toggleDuckDBLog), keyEquivalent: "")
        logItem.target = self
        logItem.state = recorder.recording ? .on : .off
        menu.addItem(logItem)
        if recorder.recording {
            let reveal = NSMenuItem(title: "Reveal Log in Finder",
                                    action: #selector(revealLog), keyEquivalent: "")
            reveal.target = self
            menu.addItem(reveal)
        }
        menu.addBarMetricsSubmenu(model: model, target: self)
        menu.addThresholdSubmenu(model: model, target: self)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Orbeat", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // detach so left-click keeps opening the popover
    }

    @objc func toggleBarMetric(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        if model.barMetrics.contains(key) { model.barMetrics.remove(key) }
        else { model.barMetrics.insert(key) }
        updateStatusTitle()
    }

    @objc func toggleRebroadcast() {
        ble?.proxy.enabled.toggle()
    }

    @objc func harder() { applyRidePress([.shiftUp]) }
    @objc func easier() { applyRidePress([.shiftDown]) }

    @objc func toggleDuckDBLog() {
        recorder.recording.toggle()
    }

    @objc func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Recorder.logURL])
    }

    @objc func connectEquipment(_ sender: NSMenuItem) {
        guard let ble, sender.tag < ble.discovered.count else { return }
        ble.connect(ble.discovered[sender.tag])
    }

    @objc func forgetEquipment(_ sender: NSMenuItem) {
        guard let ble, sender.tag < ble.discovered.count else { return }
        ble.forget(ble.discovered[sender.tag])
    }

    @objc func setThreshold(_ sender: NSMenuItem) {
        model.threshold = sender.tag
        updateStatusTitle()
    }

    @objc func customThreshold() {
        let alert = NSAlert()
        alert.messageText = "Alert Threshold"
        alert.informativeText = "Warn when BPM reaches this value."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 90, height: 24))
        let fmt = NumberFormatter()
        fmt.allowsFloats = false
        fmt.minimum = 1
        fmt.maximum = 250
        field.formatter = fmt
        if model.threshold > 0 { field.integerValue = model.threshold }
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, field.integerValue > 0 {
            model.threshold = field.integerValue
            updateStatusTitle()
        }
    }
}

private extension NSMenu {
    /// Discovered sensors + "Forget" entries for known ones.
    func addEquipmentSubmenu(from ble: BLEManager?, target: AppDelegate) {
        let equipItem = NSMenuItem(title: "Connect Equipment", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let devices = ble?.discovered ?? []
        if devices.isEmpty {
            let none = NSMenuItem(title: "Scanning… no devices yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for (i, d) in devices.enumerated() {
            let kind = d.isRide ? "Controller" : d.isPower ? "Power" : "Heart Rate"
            let item = NSMenuItem(title: "\(d.name) — \(kind)",
                                  action: #selector(AppDelegate.connectEquipment(_:)), keyEquivalent: "")
            item.target = target
            item.tag = i
            item.state = (ble?.isConnected(d) ?? false) ? .on : .off
            sub.addItem(item)
        }
        let knownDevices = devices.enumerated().filter { ble?.isKnown($0.element) ?? false }
        if !knownDevices.isEmpty {
            sub.addItem(.separator())
            for (i, d) in knownDevices {
                let item = NSMenuItem(title: "Forget \(d.name)",
                                      action: #selector(AppDelegate.forgetEquipment(_:)), keyEquivalent: "")
                item.target = target
                item.tag = i
                sub.addItem(item)
            }
        }
        equipItem.submenu = sub
        addItem(equipItem)
    }

    func addBarMetricsSubmenu(model: RideModel, target: AppDelegate) {
        let barItem = NSMenuItem(title: "Menu Bar Shows", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, key) in [("Heart Rate", "heart"), ("Power", "power"),
                             ("Cadence", "rpm"), ("Speed", "speed")] {
            let item = NSMenuItem(title: title,
                                  action: #selector(AppDelegate.toggleBarMetric(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = key
            item.state = model.barMetrics.contains(key) ? .on : .off
            sub.addItem(item)
        }
        barItem.submenu = sub
        addItem(barItem)
    }

    func addThresholdSubmenu(model: RideModel, target: AppDelegate) {
        let thresholdItem = NSMenuItem(title: "Alert Threshold", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let presets = [0, 100, 110, 120, 130, 140, 150, 160, 170, 180]
        for v in presets {
            let item = NSMenuItem(title: v == 0 ? "Off" : "\(v) BPM",
                                  action: #selector(AppDelegate.setThreshold(_:)), keyEquivalent: "")
            item.target = target
            item.tag = v
            item.state = model.threshold == v ? .on : .off
            sub.addItem(item)
        }
        let isCustom = !presets.contains(model.threshold)
        let custom = NSMenuItem(title: isCustom ? "Custom (\(model.threshold) BPM)…" : "Custom…",
                                action: #selector(AppDelegate.customThreshold), keyEquivalent: "")
        custom.target = target
        custom.state = isCustom ? .on : .off
        sub.addItem(custom)
        thresholdItem.submenu = sub
        addItem(thresholdItem)
    }
}
