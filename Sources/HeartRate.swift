import SwiftUI
import Combine

/// Heart-rate engine.
///
/// Currently drives a simulated live BPM signal identical in spirit to the
/// design mockup (random walk, ~1.1s tick). Swap `tick()` for a real Fitbit
/// feed by filling in `FitbitClient` — see Fitbit.swift.
final class HeartRate: ObservableObject {
    /// Master switch for the fake signal. Off → only real BLE data drives the UI.
    static let simulated = false

    struct Sample {
        let time: Date
        let bpm: Int
    }

    @Published var bpm: Int = 0
    @Published var history: [Sample] = []
    @Published var minBPM: Int = 0
    @Published var maxBPM: Int = 0
    let restingBPM: Int = 58
    @Published var lastSync: Date = .distantPast
    /// True while the newest reading (any metric) is < 60 s old (matches the
    /// Live Activity staleDate). Timer-driven so the UI goes stale even when
    /// no new data arrives to trigger a render.
    @Published private(set) var isFresh = false
    @Published var sourceName: String = "Simulated"
    @Published var bleStatus: String = "Starting…"
    /// Alert threshold in BPM; 0 = off. Persisted.
    @Published var threshold: Int = UserDefaults.standard.integer(forKey: "threshold") {
        didSet { UserDefaults.standard.set(threshold, forKey: "threshold") }
    }
    var overThreshold: Bool { threshold > 0 && hasData && isFresh && bpm >= threshold }
    /// Instantaneous power from a BLE cycling power meter (KICKR etc.); nil = none connected.
    @Published var watts: Int? = nil
    @Published var cadence: Int? = nil        // crank RPM
    @Published var speedKmh: Double? = nil    // virtual speed from wheel revs
    @Published var powerSource: String = ""
    /// Metrics shown in the menu bar: any of "heart", "power", "rpm", "speed". Persisted.
    @Published var barMetrics: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "barMetrics") ?? ["heart"]) {
        didSet { UserDefaults.standard.set(Array(barMetrics), forKey: "barMetrics") }
    }
    /// True once a real BLE device feeds data — suspends the simulator.
    private(set) var isLive = false

    private var timer: AnyCancellable?
    private var freshTimer: AnyCancellable?

    /// Seed identical to the mockup so first paint matches the design.
    private static let seed = [68,70,69,72,71,73,75,74,72,70,69,71,73,76,78,77,75,73,
                              71,70,72,74,73,71,69,68,70,72,75,77,79,78,76,74,72,71,73,
                              72,70,69,71,73,72,74,76,75,73,71,70,72,73,71,69,70,72,74,73,72,71,72]

    init() {
        freshTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                let f = Date().timeIntervalSince(self.lastSync) < 60
                if f != self.isFresh { self.isFresh = f }
            }
        if HeartRate.simulated {
            let now = Date()
            history = HeartRate.seed.enumerated().map { i, v in
                Sample(time: now.addingTimeInterval(Double(i - HeartRate.seed.count) * 1.1), bpm: v)
            }
            bpm = 72; minBPM = 52; maxBPM = 141
            start()
        }
    }

    /// True once any reading (real or simulated) has arrived.
    var hasData: Bool { !history.isEmpty }
    var bpmText: String { hasData && isFresh ? "\(bpm)" : "––" }
    // Stale (>120 s) reads as no value everywhere these are shown.
    var displayWatts: Int? { isFresh ? watts : nil }
    var displayCadence: Int? { isFresh ? cadence : nil }
    var displaySpeedKmh: Double? { isFresh ? speedKmh : nil }

    /// Mark a live reading as just received (any metric).
    // isFresh first: @Published emits on willSet, and the iOS app pushes a Live
    // Activity update from $lastSync — it must see isFresh already true.
    func touch() { isFresh = true; lastSync = Date() }

    func start() {
        timer = Timer.publish(every: 1.1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func stop() { timer?.cancel(); timer = nil }

    private func tick() {
        if isLive { return }   // a real device is feeding us; don't simulate
        var b = bpm + Int((((Double.random(in: 0...1) - 0.5) * 7)).rounded())
        b = max(58, min(92, b))
        record(b)
    }

    /// Push a real reading from a BLE device.
    func ingest(_ b: Int) { record(b) }

    /// Toggle live-source mode (called by the BLE manager on connect/disconnect).
    func setLive(_ live: Bool, source: String) {
        isLive = live
        sourceName = source
    }

    private func record(_ b: Int) {
        let first = history.isEmpty
        bpm = b
        history.append(Sample(time: Date(), bpm: b))
        if history.count > 60 { history.removeFirst(history.count - 60) }
        minBPM = first ? b : min(minBPM, b)
        maxBPM = first ? b : max(maxBPM, b)
        touch()
    }

    /// Heart-rate zone matching the design's `zoneFor`.
    var zone: String {
        switch bpm {
        case ..<60: return "Resting"
        case ..<100: return "Fat Burn"
        case ..<140: return "Cardio"
        default: return "Peak"
        }
    }

    var zoneColor: Color {
        switch bpm {
        case ..<60: return Color(red: 0.18, green: 0.82, blue: 0.35)   // green
        case ..<100: return Color(red: 1.0, green: 0.62, blue: 0.04)   // orange
        case ..<140: return Color(red: 1.0, green: 0.22, blue: 0.37)   // red
        default: return Color(red: 0.74, green: 0.35, blue: 0.95)      // purple
        }
    }

    var syncLabel: String {
        let s = Int(Date().timeIntervalSince(lastSync))
        if s < 2 { return "Synced just now" }
        return "Synced \(s)s ago"
    }
}
