import ActivityKit
import SwiftUI

/// Live Activity payload shared by the app (which starts/updates the activity)
/// and the widget extension (which renders it in the Dynamic Island).
struct OrbeatAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var bpm: Int
        var watts: Int?
        var cadence: Int?
        /// Over the user's alert threshold — widget renders red warning state.
        var over: Bool = false
    }
}

/// Zone color for a BPM value — mirrors RideModel.zoneColor, which the widget
/// target doesn't compile (it drags in Combine/UserDefaults state it can't use).
func orbeatZoneColor(_ bpm: Int) -> Color {
    switch bpm {
    case ..<60: return Color(red: 0.18, green: 0.82, blue: 0.35)
    case ..<100: return Color(red: 1.0, green: 0.62, blue: 0.04)
    case ..<140: return Color(red: 1.0, green: 0.22, blue: 0.37)
    default: return Color(red: 0.74, green: 0.35, blue: 0.95)
    }
}
