import Foundation
import Combine
import CoreData
import SwiftData

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

/// A finished session as stored and synced through the user's private
/// CloudKit database. CloudKit rules: every attribute defaulted, no unique
/// constraints. Samples ride along as one JSON blob.
@Model final class SessionRecord {
    var id = UUID()
    var start = Date()
    var end: Date?
    @Attribute(.externalStorage) var samples = Data()

    init(_ s: Session) {
        id = s.id
        start = s.start
        end = s.end
        samples = (try? JSONEncoder().encode(s.samples)) ?? Data()
    }

    var session: Session {
        Session(id: id, start: start, end: end,
                samples: (try? JSONDecoder().decode([Session.Sample].self, from: samples)) ?? [])
    }
}

/// Start/stop a session and keep the finished ones. History lives in
/// SwiftData; `.automatic` syncs it via the iCloud container named in the
/// entitlements, or stays local when the build has none or sync is off.
/// ponytail: `past` decodes every session on each change; page it past ~500 sessions.
final class SessionStore: ObservableObject {
    @Published private(set) var active: Session?
    @Published private(set) var past: [Session] = []
    /// Elapsed seconds of the active session; ticks so the UI can show a clock.
    @Published private(set) var elapsed: TimeInterval = 0

    private let context: ModelContext
    private var remote: AnyCancellable?

    /// Pre-SwiftData history, imported once per device.
    static let legacyURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("sessions.json")

    /// Own folder: the Mac app isn't sandboxed, so the default
    /// "default.store" would be shared with every other unsandboxed app.
    static let storeURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Orbeat/sessions.store")

    /// iCloud sync on/off (history + threshold); read once at launch.
    static let cloudSyncKey = "iCloudSync"
    static var cloudSync: Bool { UserDefaults.standard.object(forKey: cloudSyncKey) as? Bool ?? true }

    init() {
        let container: ModelContainer
        do {
            try FileManager.default.createDirectory(at: Self.storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            container = try ModelContainer(for: SessionRecord.self,
                                           configurations: ModelConfiguration(url: Self.storeURL,
                                                                              cloudKitDatabase: Self.cloudSync ? .automatic : .none))
        } catch { fatalError("SwiftData store: \(error)") }
        context = ModelContext(container)
        importLegacy()
        reload()
        // Sessions recorded on the other device arrive via CloudKit import.
        remote = NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
    }

    func start() { active = Session(start: Date()); elapsed = 0 }

    func stop() {
        guard var s = active else { return }
        s.end = Date()
        active = nil
        // Ignore accidental taps: nothing sampled and under 10 s.
        if s.samples.isEmpty && s.duration < 10 { return }
        context.insert(SessionRecord(s))
        save()
    }

    func delete(_ session: Session) {
        // Per-object delete: a batch delete (delete(model:where:)) bypasses
        // CloudKit mirroring, so the other device would keep the session.
        let id = session.id
        let match = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
        ((try? context.fetch(match)) ?? []).forEach(context.delete)
        save()
    }

    /// Call on every reading and once a second; samples at most 1 Hz. Records
    /// only fresh readings, so a dropped strap leaves a gap, not a flat line.
    func tick(_ m: RideModel) {
        guard active != nil else { return }
        elapsed = active!.duration
        if let last = active!.samples.last, elapsed - last.t < 0.95 { return }
        let live = m.hasData && m.isFresh
        let s = Session.Sample(t: elapsed, bpm: live ? m.bpm : nil,
                               watts: m.displayWatts, rpm: m.displayCadence, kmh: m.displaySpeedKmh)
        if s.bpm != nil || s.watts != nil { active!.samples.append(s) }
    }

    private func save() {
        do { try context.save() } catch { NSLog("Orbeat: session save failed: \(error)") }
        reload()
    }

    private func reload() {
        let all = FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.start, order: .reverse)])
        past = ((try? context.fetch(all)) ?? []).map(\.session)
    }

    /// Moves the old sessions.json into SwiftData, then renames it (kept as a
    /// backup) so it is not imported twice — CloudKit can't dedupe by id. A
    /// failed save leaves the file in place to retry next launch.
    private func importLegacy() {
        let url = Self.legacyURL
        guard let data = try? Data(contentsOf: url),
              let old = try? JSONDecoder().decode([Session].self, from: data) else { return }
        old.forEach { context.insert(SessionRecord($0)) }
        do { try context.save() } catch { context.rollback(); return }
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("imported"))
    }
}
