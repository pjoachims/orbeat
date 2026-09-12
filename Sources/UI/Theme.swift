import SwiftUI

// Shared look for the macOS card and the iOS screen: one brand red, zone as
// the only other signal color, tight numerals, quiet labels. No gradients.

let orbeatRed = Color(red: 1.0, green: 0.22, blue: 0.37)   // #FF375F

/// Zone palette, cool → hot. Peak is the brand red, same as the heart glyph.
/// Mirrored in ios/Shared/OrbeatActivity.swift for the widget target.
func rideZoneColor(_ bpm: Int) -> Color {
    switch bpm {
    case ..<60: return Color(red: 0.50, green: 0.65, blue: 1.0)    // Resting  #7FA6FF
    case ..<100: return Color(red: 0.30, green: 0.85, blue: 0.48)  // Fat Burn #4DD97B
    case ..<140: return Color(red: 1.0, green: 0.69, blue: 0.13)   // Cardio   #FFB020
    default: return orbeatRed                                      // Peak
    }
}

/// Small uppercase tracking label above a value.
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(1.0)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Heart glyph that beats at the actual heart rate (quick systole, slow relax).
/// Still when there is no live signal.
struct BeatingHeart: View {
    var bpm: Int
    var live: Bool
    var size: CGFloat
    var color: Color = orbeatRed

    var body: some View {
        if live && bpm > 0 {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                let period = 60.0 / Double(bpm)
                let t = ctx.date.timeIntervalSinceReferenceDate
                let phase = t.truncatingRemainder(dividingBy: period) / period
                let s = phase < 0.12 ? phase / 0.12 : max(0, 1 - (phase - 0.12) / 0.4)
                glyph.scaleEffect(1 + 0.13 * s)
            }
        } else {
            glyph.opacity(0.5)
        }
    }

    private var glyph: some View {
        Image(systemName: "heart.fill").font(.system(size: size, weight: .semibold)).foregroundStyle(color)
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

/// Sparkline of recent BPM: thin area + line + leading dot, auto-ranged to the
/// data (never clips a high-cardio ride flat against the top). Hover/pointer
/// shows the nearest sample.
struct Sparkline: View {
    let history: [RideModel.Sample]
    var tint: Color = orbeatRed
    @State private var hoverX: CGFloat? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let n = max(history.count - 1, 1)
            let vals = history.map { Double($0.bpm) }
            let minV = vals.min() ?? 60, maxV = vals.max() ?? 100
            let span = max(maxV - minV, 16)
            let lo = (minV + maxV) / 2 - span / 2 - 2
            let hi = (minV + maxV) / 2 + span / 2 + 2
            let pts: [CGPoint] = history.enumerated().map { i, s in
                let x = Double(i) / Double(n) * w
                let y = h - (Double(s.bpm) - lo) / (hi - lo) * h
                return CGPoint(x: x, y: y)
            }
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(tint.opacity(0.22)).frame(width: 13, height: 13).position(last)
                    Circle().fill(tint).frame(width: 5.5, height: 5.5).position(last)
                }
                if let hx = hoverX, !pts.isEmpty {
                    let i = min(max(Int((hx / w * CGFloat(n)).rounded()), 0), pts.count - 1)
                    let pt = pts[i]
                    let s = history[i]
                    Path { p in
                        p.move(to: CGPoint(x: pt.x, y: 0))
                        p.addLine(to: CGPoint(x: pt.x, y: h))
                    }
                    .stroke(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    Circle().fill(tint).frame(width: 7, height: 7)
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

/// Tile background shared by metrics and the trainer stepper.
struct Tile: ViewModifier {
    var padding: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.primary.opacity(0.06)))
    }
}

/// Label-over-value metric. Units live in the label so the number stays clean
/// and never overflows ("KM/H" · "33.0").
struct MetricTile: View {
    let label: String
    let value: String
    var valueSize: CGFloat = 22
    var padding: CGFloat = 12
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(text: label)
            Text(value)
                .font(.system(size: valueSize, weight: .semibold))
                .monospacedDigit()
                .kerning(-0.5)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(Tile(padding: padding))
    }
}

/// Current trainer target with − / + steppers (same policy as the paddles).
struct TrainerStepper: View {
    let mode: TrainerMode?
    var padding: CGFloat = 12
    let onStep: (HandlebarInput) -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(text: "Trainer · ±\(mode?.stepLabel.dropFirst() ?? "")")
                Text(mode?.label ?? "Ready")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 4)
            stepButton("minus") { onStep(.shiftDown) }
            stepButton("plus") { onStep(.shiftUp) }
        }
        .modifier(Tile(padding: padding))
    }

    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: 36, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Zone chip: dot + name, tinted by zone; neutral when there is no signal.
struct ZoneChip: View {
    @ObservedObject var model: RideModel
    var body: some View {
        let live = model.hasData && model.isFresh
        let color = live ? rideZoneColor(model.bpm) : Color.secondary
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(model.hasData ? (live ? model.zone : "Signal lost") : "No device")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(live ? color : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(live ? 0.14 : 0.08)))
    }
}
