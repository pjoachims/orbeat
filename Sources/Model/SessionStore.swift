import Foundation
import Combine

/// One recorded session of anything — a ride, a run, a gym set. Samples are
/// taken once a second from whatever the model currently shows; metrics that
/// aren't connected stay nil, so an HR-only walk and a power-meter ride share
/// one shape.
struct Session: Codable, Identifiable {
    struct Sample: Codable {
        let t: TimeInterval        // seconds since session start
        let bpm: Int?
        let watts: Int?
        let rpm: Int?
        let kmh: Double?
    }
    var id = UUID()
    var start: Date
    var end: Date?
    var samples: [Sample] = []

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
    var bpms: [Int] { samples.compactMap(\.bpm) }
    var wattsAll: [Int] { samples.compactMap(\.watts) }
    var avgBPM: Int? { bpms.isEmpty ? nil : bpms.reduce(0, +) / bpms.count }
    var maxBPM: Int? { bpms.max() }
    var avgWatts: Int? { wattsAll.isEmpty ? nil : wattsAll.reduce(0, +) / wattsAll.count }
    var maxWatts: Int? { wattsAll.max() }
    var distanceKm: Double { samples.compactMap(\.kmh).reduce(0) { $0 + $1 / 3600 } }
    /// Seconds spent per zone (same buckets as RideModel.zone), zones in display order.
    var zoneSeconds: [(zone: String, seconds: Int)] {
        var t = ["Resting": 0, "Fat Burn": 0, "Cardio": 0, "Peak": 0]
        for b in bpms { t[RideModel.zoneName(b), default: 0] += 1 }
        return ["Resting", "Fat Burn", "Cardio", "Peak"].map { ($0, t[$0] ?? 0) }
    }
}

/// Start/stop a session and keep the finished ones. Whole history lives in one
/// JSON file rewritten on every stop.
/// ponytail: one file, loaded whole; move to per-session files past ~100 sessions.
final class SessionStore: ObservableObject {
    @Published private(set) var active: Session?
    @Published private(set) var past: [Session] = []
    /// Elapsed seconds of the active session; ticks so the UI can show a clock.
    @Published private(set) var elapsed: TimeInterval = 0

    static let fileURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("sessions.json")

    init() {
        if let data = try? Data(contentsOf: SessionStore.fileURL),
           let saved = try? JSONDecoder().decode([Session].self, from: data) {
            past = saved
        }
    }

    func start() { active = Session(start: Date()); elapsed = 0 }

    func stop() {
        guard var s = active else { return }
        s.end = Date()
        active = nil
        // Ignore accidental taps: nothing sampled and under 10 s.
        if s.samples.isEmpty && s.duration < 10 { return }
        past.insert(s, at: 0)
        save()
    }

    func delete(_ session: Session) {
        past.removeAll { $0.id == session.id }
        save()
    }

    /// Call once a second. Records only fresh readings, so a dropped strap
    /// leaves a gap rather than a flat line.
    func tick(_ m: RideModel) {
        guard active != nil else { return }
        elapsed = active!.duration
        let live = m.hasData && m.isFresh
        let s = Session.Sample(t: elapsed, bpm: live ? m.bpm : nil,
                               watts: m.displayWatts, rpm: m.displayCadence, kmh: m.displaySpeedKmh)
        if s.bpm != nil || s.watts != nil { active!.samples.append(s) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(past) else { return }
        try? data.write(to: SessionStore.fileURL, options: .atomic)
    }
}
