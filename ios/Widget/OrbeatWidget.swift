import WidgetKit
import SwiftUI
import ActivityKit

@main
struct OrbeatWidgetBundle: WidgetBundle {
    var body: some Widget { OrbeatLiveActivity() }
}

struct OrbeatLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrbeatAttributes.self) { context in
            // Lock Screen / banner presentation.
            HStack(spacing: 24) {
                bpmLabel(context.state, size: 28, stale: context.isStale)
                if !context.isStale, let w = context.state.watts { wattsLabel(w, size: 28) }
                if !context.isStale, let c = context.state.cadence {
                    Text("\(c) rpm")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .activityBackgroundTint(context.state.over && !context.isStale
                                    ? .red.opacity(0.75) : .black.opacity(0.8))
        } dynamicIsland: { context in
            DynamicIsland {
                // Everything centered; compact mode can't (camera cutout owns the middle).
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 24) {
                        bpmLabel(context.state, size: 30, stale: context.isStale)
                        if !context.isStale, let w = context.state.watts { wattsLabel(w, size: 30) }
                        if !context.isStale, let c = context.state.cadence {
                            Text("\(c) rpm")
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            } compactLeading: {
                // Bias toward the cutout — the middle itself is the camera, unreachable.
                bpmLabel(context.state, size: 15, stale: context.isStale)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } compactTrailing: {
                if !context.isStale, let w = context.state.watts {
                    wattsLabel(w, size: 15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } minimal: {
                Text(!context.isStale && context.state.bpm > 0 ? "\(context.state.bpm)" : "––")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(context.isStale ? .gray : orbeatZoneColor(context.state.bpm))
            }
            .keylineTint(context.state.over && !context.isStale ? .red : nil)
        }
    }

    private func bpmLabel(_ s: OrbeatAttributes.ContentState, size: CGFloat,
                          stale: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: s.over && !stale ? "exclamationmark.triangle.fill" : "heart.fill")
                .font(.system(size: size * 0.75))
                .foregroundStyle(stale ? .gray : s.over ? .red : orbeatZoneColor(s.bpm))
            Text(!stale && s.bpm > 0 ? "\(s.bpm)" : "––")
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(stale ? .gray : s.over ? .red : .white)
        }
    }

    private func wattsLabel(_ w: Int, size: CGFloat) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.fill")
                .font(.system(size: size * 0.7))
                .foregroundStyle(.yellow)
            Text("\(w)")
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
    }
}
