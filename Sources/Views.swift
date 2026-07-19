import SwiftUI

let orbeatRed = Color(red: 1.0, green: 0.22, blue: 0.37)   // #FF375F

/// Animated beating heart glyph.
struct BeatingHeart: View {
    var size: CGFloat = 13
    @State private var beat = false
    var body: some View {
        Text("♥")
            .font(.system(size: size))
            .foregroundStyle(orbeatRed)
            .scaleEffect(beat ? 1.22 : 1.0)
            .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: beat)
            .onAppear { beat = true }
    }
}

/// Pulsing "LIVE" dot; grey static "OFFLINE" when the signal is stale.
struct LiveDot: View {
    var live = true
    @State private var on = true
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(live ? orbeatRed : Color.secondary).frame(width: 5, height: 5)
                .opacity(live ? (on ? 1 : 0.25) : 0.6)
                .animation(live ? .easeInOut(duration: 0.67).repeatForever(autoreverses: true) : .default,
                           value: on)
            Text(live ? "LIVE" : "OFFLINE")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.secondary)
        }
        .onAppear { on.toggle() }
    }
}

/// Sparkline of recent BPM, gradient area + line + leading dot. Mirrors the SVG.
/// Hovering shows the nearest sample's BPM and timestamp.
struct Sparkline: View {
    let history: [HeartRate.Sample]
    private let lo = 48.0, hi = 110.0
    @State private var hoverX: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = max(history.count - 1, 1)
            let pts: [CGPoint] = history.enumerated().map { i, s in
                let cv = min(max(Double(s.bpm), lo), hi)
                let x = Double(i) / Double(n) * w
                let y = h - (cv - lo) / (hi - lo) * h
                return CGPoint(x: x, y: y)
            }
            ZStack {
                // area
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [orbeatRed.opacity(0.34), orbeatRed.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                // line
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(orbeatRed, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                // leading dot
                if let last = pts.last {
                    Circle().fill(orbeatRed.opacity(0.22)).frame(width: 13, height: 13).position(last)
                    Circle().fill(orbeatRed).frame(width: 5.6, height: 5.6).position(last)
                }
                // hover crosshair + tooltip
                if let hx = hoverX, !pts.isEmpty {
                    let i = min(max(Int((hx / w * CGFloat(n)).rounded()), 0), pts.count - 1)
                    let pt = pts[i]
                    let s = history[i]
                    Path { p in
                        p.move(to: CGPoint(x: pt.x, y: 0))
                        p.addLine(to: CGPoint(x: pt.x, y: h))
                    }
                    .stroke(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    Circle().fill(orbeatRed).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.background, lineWidth: 1.5))
                        .position(pt)
                    Text("\(s.bpm) BPM · \(s.time.formatted(date: .omitted, time: .standard))")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.background.opacity(0.9)).shadow(radius: 2))
                        .fixedSize()
                        .position(x: min(max(pt.x, 55), w - 55), y: -14)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hoverX = p.x
                case .ended: hoverX = nil
                }
            }
        }
    }
}

/// Red banner shown top-center of the screen while BPM is over the threshold.
struct WarningHUD: View {
    @ObservedObject var hr: HeartRate
    @State private var flash = false
    var body: some View {
        HStack(spacing: 8) {
            Text("♥").font(.system(size: 16))
                .opacity(flash ? 1 : 0.4)
                .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: flash)
            Text("\(hr.bpm) BPM — over \(hr.threshold)")
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color(nsColor: .systemRed)))
        .padding(10)
        .onAppear { flash = true }
    }
}

/// The heart-rate card. `compact` = menu-bar dropdown sizing; else floating widget.
struct HeartCard: View {
    @ObservedObject var hr: HeartRate
    var compact: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // header
            HStack {
                if compact {
                    HStack(spacing: 7) {
                        BeatingHeart(size: 13)
                        Text("Heart Rate").font(.system(size: 13, weight: .semibold))
                    }
                } else {
                    Text("HEART RATE")
                        .font(.system(size: 11, weight: .semibold)).kerning(1.1)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                LiveDot(live: hr.isFresh)
            }
            .padding(.bottom, compact ? 10 : 14)

            // big number
            HStack(alignment: .lastTextBaseline, spacing: compact ? 7 : 9) {
                if !compact { Spacer() }
                Text(hr.bpmText)
                    .font(.system(size: compact ? 46 : 76, weight: .semibold))
                    .monospacedDigit()
                    .kerning(compact ? -2 : -3)
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.4), value: hr.bpm)
                Text("BPM")
                    .font(.system(size: compact ? 13 : 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, compact ? 7 : 12)
                if !compact { Spacer() }
            }

            Sparkline(history: hr.history)
                .frame(height: compact ? 52 : 60)
                .padding(.vertical, compact ? 6 : 8)
                .opacity(hr.isFresh ? 1 : 0.35)   // old curve mustn't read as current

            // stats
            if compact {
                HStack {
                    stat("Resting", txt(hr.restingBPM)); Spacer()
                    stat("Min", txt(hr.minBPM)); Spacer()
                    stat("Max", txt(hr.maxBPM))
                }
                .font(.system(size: 11))
                .padding(.vertical, 9)
                .overlay(Divider(), alignment: .top)
                .overlay(Divider(), alignment: .bottom)
                if hr.watts != nil {
                    HStack {
                        stat("⚡", wattsTxt); Spacer()
                        stat("RPM", cadenceTxt); Spacer()
                        stat("Speed", speedTxt)
                    }
                    .font(.system(size: 11))
                    .padding(.vertical, 9)
                    .overlay(Divider(), alignment: .bottom)
                }
            } else {
                HStack(spacing: 6) {
                    bigStat("RESTING", txt(hr.restingBPM))
                    bigStat("MIN", txt(hr.minBPM))
                    bigStat("MAX", txt(hr.maxBPM))
                }
                .padding(.top, 15)
                .overlay(Divider(), alignment: .top)
                if hr.watts != nil {
                    HStack(spacing: 6) {
                        bigStat("POWER", wattsTxt)
                        bigStat("RPM", cadenceTxt)
                        bigStat("SPEED", speedTxt)
                    }
                    .padding(.top, 15)
                }
            }

            // footer
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(hr.hasData && hr.isFresh ? hr.zoneColor : .secondary)
                        .frame(width: 6, height: 6)
                    Text(hr.hasData ? (hr.isFresh ? hr.zone : "Signal lost") : "No device")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, compact ? 10 : 11)
                .padding(.vertical, compact ? 4 : 5)
                .background(Capsule().fill(.primary.opacity(0.08)))
                Spacer()
                Text(hr.hasData ? hr.syncLabel : hr.bleStatus)
                    .font(.system(size: compact ? 10.5 : 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, compact ? 11 : 15)
        }
        .padding(compact ? 16 : 22)
        .frame(width: compact ? 262 : 288)
    }

    private func txt(_ v: Int) -> String { hr.hasData && hr.isFresh ? "\(v)" : "––" }
    private var wattsTxt: String { hr.displayWatts.map { "\($0) W" } ?? "––" }
    private var cadenceTxt: String { hr.displayCadence.map { "\($0)" } ?? "––" }
    private var speedTxt: String { hr.displaySpeedKmh.map { String(format: "%.1f km/h", $0) } ?? "––" }
    private func stat(_ label: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(v).fontWeight(.semibold)
        }
    }
    private func bigStat(_ label: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).kerning(0.5).foregroundStyle(.secondary)
            Text(v).font(.system(size: 18, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
