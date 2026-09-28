import SwiftUI
import AppKit

/// Window/panel hosting: menu-bar title, popover, floating widget, warning HUD.
extension AppDelegate {
    func updateStatusTitle() {
        guard let button = statusItem.button else { return }
        let over = model.overThreshold
        let heartColor = over ? NSColor.white : NSColor(red: 1.0, green: 0.22, blue: 0.37, alpha: 1)
        let valueColor = over ? NSColor.white : NSColor.labelColor
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: valueColor]
        var segs: [(symbol: String, value: String, color: NSColor)] = []
        if model.barMetrics.contains("heart") { segs.append(("heart.fill", model.bpmText, heartColor)) }
        if model.barMetrics.contains("power") {
            segs.append(("bolt.fill", model.displayWatts.map { "\($0)" } ?? "––", valueColor))
        }
        if model.barMetrics.contains("rpm") {
            segs.append(("arrow.trianglehead.2.clockwise.rotate.90",
                         model.displayCadence.map { "\($0)" } ?? "––", valueColor))
        }
        if model.barMetrics.contains("speed") {
            segs.append(("gauge.with.needle", model.displaySpeedKmh.map { String(format: "%.1f", $0) } ?? "––", valueColor))
        }
        if segs.isEmpty { segs = [("heart.fill", model.bpmText, heartColor)] }   // never a blank bar
        let s = NSMutableAttributedString()
        for (idx, seg) in segs.enumerated() {
            if idx > 0 { s.append(NSAttributedString(string: "   ", attributes: valueAttrs)) }
            s.append(Self.symbol(seg.symbol, color: seg.color))
            s.append(NSAttributedString(string: " " + seg.value, attributes: valueAttrs))
        }
        button.attributedTitle = s
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.backgroundColor = over ? NSColor.systemRed.cgColor : nil
        updateWarningHUD()
    }

    /// An SF Symbol as an inline text attachment, tinted, baseline-aligned to 13 pt text.
    private static func symbol(_ name: String, color: NSColor) -> NSAttributedString {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return NSAttributedString(string: "") }
        let a = NSTextAttachment()
        a.image = img
        a.bounds = CGRect(x: 0, y: -2, width: img.size.width, height: img.size.height)
        return NSAttributedString(attachment: a)
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
            HeartCard(model: model, compact: false,
                      onStep: { [weak self] in self?.applyRidePress([$0]) })
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 312, height: 400),
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
