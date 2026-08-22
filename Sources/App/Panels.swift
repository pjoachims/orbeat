import SwiftUI
import AppKit

/// Window/panel hosting: menu-bar title, popover, floating widget, warning HUD.
extension AppDelegate {
    func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let over = model.overThreshold
        let heartColor = over ? NSColor.white : NSColor(red: 1.0, green: 0.22, blue: 0.37, alpha: 1)
        let glyphAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: over ? NSColor.white : NSColor.labelColor]
        var segs: [(glyph: String, value: String, color: NSColor?)] = []
        if model.barMetrics.contains("heart") { segs.append(("♥ ", model.bpmText, heartColor)) }
        if model.barMetrics.contains("power") {
            segs.append(("⚡", model.displayWatts.map { "\($0)" } ?? "––", nil))
        }
        if model.barMetrics.contains("rpm") {
            segs.append(("⟳ ", model.displayCadence.map { "\($0)" } ?? "––", nil))
        }
        if model.barMetrics.contains("speed") {
            segs.append(("≫ ", model.displaySpeedKmh.map { String(format: "%.1f", $0) } ?? "––", nil))
        }
        if segs.isEmpty { segs = [("♥ ", model.bpmText, heartColor)] }   // never a blank bar
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

    func updateWarningHUD() {
        if model.overThreshold {
            guard warningPanel == nil, let screen = NSScreen.main else { return }
            let host = NSHostingController(rootView: WarningHUD(model: model))
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

    func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc func toggleFloating() {
        if let panel = floatingPanel {
            panel.close()
            floatingPanel = nil
            return
        }
        let host = NSHostingController(rootView:
            HeartCard(model: model, compact: false)
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
