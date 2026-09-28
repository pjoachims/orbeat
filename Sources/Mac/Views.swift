import SwiftUI

/// Red banner shown top-center of the screen while BPM is over the threshold.
struct WarningHUD: View {
    @ObservedObject var model: RideModel
    var body: some View {
        HStack(spacing: 8) {
            BeatingHeart(bpm: model.bpm, live: true, size: 14, color: .white)
            Text("\(model.bpm) BPM — over \(model.threshold)")
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color(nsColor: .systemRed)))
        .padding(10)
    }
}

/// The ride card. `compact` = menu-bar popover sizing; else floating widget.
struct HeartCard: View {
    @ObservedObject var model: RideModel
    var compact: Bool = true
    /// Trainer − / + from the card; nil hides the stepper even when a trainer is attached.
    var onStep: ((HandlebarInput) -> Void)? = nil

    private var live: Bool { model.hasData && model.isFresh }
    private var zone: Color { live ? rideZoneColor(model.bpm) : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // header
            HStack {
                HStack(spacing: 7) {
                    BeatingHeart(bpm: model.bpm, live: live, size: compact ? 12 : 13)
                    Text("Heart Rate").font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                LiveDot(live: model.isFresh)
            }
            .padding(.bottom, compact ? 8 : 12)

            // big number
            HStack(alignment: .lastTextBaseline, spacing: compact ? 6 : 8) {
                Text(model.bpmText)
                    .font(.system(size: compact ? 52 : 84, weight: .semibold))
                    .monospacedDigit()
                    .kerning(compact ? -2.5 : -4)
                    .contentTransition(.numericText())
                    .animation(.spring(duration: 0.4), value: model.bpm)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
                Text("BPM")
                    .font(.system(size: compact ? 12 : 14, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, compact ? 8 : 14)
                Spacer()
                ZoneChip(model: model).padding(.bottom, compact ? 8 : 14)
            }

            Sparkline(history: model.history, tint: zone)
                .frame(height: compact ? 48 : 64)
                .padding(.top, compact ? 4 : 8)
                .padding(.bottom, compact ? 10 : 14)
                .opacity(live ? 1 : 0.35)   // old curve mustn't read as current

            // session range
            HStack(spacing: 0) {
                small("Min", txt(model.minBPM))
                Spacer()
                small("Avg", txt(model.avgBPM))
                Spacer()
                small("Max", txt(model.maxBPM))
            }
            .padding(.vertical, compact ? 8 : 10)
            .overlay(Divider(), alignment: .top)
            .overlay(Divider(), alignment: .bottom)

            // power metrics + trainer
            if model.watts != nil || model.trainerControllable {
                VStack(spacing: 6) {
                    if model.watts != nil {
                        HStack(spacing: 6) {
                            MetricTile(label: "Watts", value: wattsTxt,
                                       valueSize: compact ? 18 : 22, padding: compact ? 10 : 12)
                            MetricTile(label: "RPM", value: cadenceTxt,
                                       valueSize: compact ? 18 : 22, padding: compact ? 10 : 12)
                            MetricTile(label: "km/h", value: speedTxt,
                                       valueSize: compact ? 18 : 22, padding: compact ? 10 : 12)
                        }
                    }
                    if model.trainerControllable, let onStep {
                        TrainerStepper(mode: model.trainerMode, padding: compact ? 10 : 12, onStep: onStep)
                    }
                }
                .padding(.top, compact ? 10 : 12)
            }

            // footer
            HStack {
                Text(model.sourceName)
                    .font(.system(size: compact ? 10.5 : 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Text(model.hasData ? model.syncLabel : model.bleStatus)
                    .font(.system(size: compact ? 10.5 : 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.top, compact ? 10 : 14)
        }
        .padding(compact ? 16 : 22)
        .frame(width: compact ? 272 : 312)
    }

    private func txt(_ v: Int) -> String { live ? "\(v)" : "––" }
    private var wattsTxt: String { model.displayWatts.map { "\($0)" } ?? "––" }
    private var cadenceTxt: String { model.displayCadence.map { "\($0)" } ?? "––" }
    private var speedTxt: String { model.displaySpeedKmh.map { String(format: "%.1f", $0) } ?? "––" }

    private func small(_ label: String, _ v: String) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(v).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
    }
}
