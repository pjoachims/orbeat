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
    case ..<60: return Color(red: 0.50, green: 0.65, blue: 1.0)    // Resting  #7FA6FF
    case ..<100: return Color(red: 0.30, green: 0.85, blue: 0.48)  // Fat Burn #4DD97B
    case ..<140: return Color(red: 1.0, green: 0.69, blue: 0.13)   // Cardio   #FFB020
    default: return Color(red: 1.0, green: 0.22, blue: 0.37)       // Peak = brand red
    }
}
