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

    /// Recorded (moving) time: pauses and resumes don't count.
    /// ponytail: a sensor lost before stop trims the tail; store the clock if that matters.
    var duration: TimeInterval { samples.last?.t ?? 0 }
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
    /// Not @Published: a new sample every second would re-render every view
    /// on the store, and the session charts redo their work over all samples
    /// so far. tick publishes by hand, and only while `uiVisible`; start, stop
    /// and pause publish through `clock`.
    private(set) var active: Session?
    @Published private(set) var past: [Session] = []
    /// Elapsed seconds of the active session; ticks so the UI can show a clock.
    private(set) var elapsed: TimeInterval = 0
    /// false while the iOS app is in the background. Rendering there anyway
    /// grew with ride length until iOS killed the app ~75 min in (cpu usage:
    /// 80 % over 60 s). Back in front, the UI catches up at once.
    var uiVisible = true {
        didSet { if uiVisible, !oldValue { objectWillChange.send() } }
    }
    /// The active session's clock (nil = not recording here).
    @Published private(set) var clock: SessionClock?

    private let context: ModelContext
    private var remote: AnyCancellable?
    /// Last time the running session was written to the store / sent to the backend.
    private var savedAt = Date.distantPast
    private var uploadedAt = Date.distantPast

    /// The running session is written to the store this often, so a crash or
    /// iOS killing the app loses at most this much; relaunch picks it back up.
    static let checkpointEvery: TimeInterval = 60
    /// ...and sent to the health backend this often while it records.
    static let uploadEvery: TimeInterval = 300
    /// A checkpoint older than this at launch is finished, not resumed.
    static let resumeWithin: TimeInterval = 6 * 3600
    /// Id of the session recording on THIS device (others' unfinished records sync in too).
    private static let activeKey = "activeSessionID"
    private static let activeSavedKey = "activeSessionSavedAt"

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
        restoreActive()
        reload()
        // Sessions recorded on the other device arrive via CloudKit import.
        remote = NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
    }

    func start() {
        active = Session(start: Date()); elapsed = 0; clock = .running(since: Date())
        UserDefaults.standard.set(active!.id.uuidString, forKey: Self.activeKey)
        savedAt = Date(); uploadedAt = Date()
    }

    /// Reopen a saved session: new samples continue its clock.
    func resume(_ s: Session) {
        var s = s
        s.end = nil
        active = s
        elapsed = s.duration
        clock = SessionClock.paused(elapsed: s.duration).resuming()
        UserDefaults.standard.set(s.id.uuidString, forKey: Self.activeKey)
        savedAt = Date(); uploadedAt = Date()
    }

    func setPaused(_ paused: Bool) {
        guard let c = clock, c.isPaused != paused else { return }
        clock = paused ? c.pausing() : c.resuming()
        elapsed = clock!.elapsed()
        checkpoint()
    }

    func stop() {
        guard var s = active else { return }
        s.end = Date()
        active = nil
        clock = nil
        UserDefaults.standard.removeObject(forKey: Self.activeKey)
        // Nothing sampled (accidental tap, no sensors): nothing to keep.
        if s.samples.isEmpty { return }
        write(s)
        save()
    }

    /// Writes the running session (end = nil) to the store now, and sends it
    /// to the backend when `uploadEvery` has passed. Called from tick every
    /// `checkpointEvery`, and by the app when it goes to the background.
    func checkpoint() {
        guard let s = active, !s.samples.isEmpty else { return }
        let now = Date()
        savedAt = now
        write(s)
        do { try context.save() } catch { NSLog("Orbeat: checkpoint failed: \(error)") }
        UserDefaults.standard.set(now, forKey: Self.activeSavedKey)
        if RideUpload.auto, now.timeIntervalSince(uploadedAt) >= Self.uploadEvery {
            uploadedAt = now
            RideUpload.run(past.filter { $0.id != s.id } + [s])
        }
    }

    /// Insert or update the record for `s` (a resumed session updates in place).
    /// ponytail: continued on both devices while unlinked, last save wins.
    private func write(_ s: Session) {
        let id = s.id
        let match = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
        if let r = try? context.fetch(match).first {
            r.end = s.end
            r.samples = SessionRecord(s).samples
        } else {
            context.insert(SessionRecord(s))
        }
    }

    /// The app died mid-session (crash, iOS killed it): pick the last
    /// checkpoint back up and keep recording, the gap not counted. Too old →
    /// close it at its last checkpoint instead.
    private func restoreActive() {
        let d = UserDefaults.standard
        guard let raw = d.string(forKey: Self.activeKey), let id = UUID(uuidString: raw) else { return }
        let match = FetchDescriptor<SessionRecord>(predicate: #Predicate { $0.id == id })
        guard let r = try? context.fetch(match).first, r.end == nil else {
            d.removeObject(forKey: Self.activeKey); return
        }
        let s = r.session
        let last = d.object(forKey: Self.activeSavedKey) as? Date ?? s.start.addingTimeInterval(s.duration)
        if Date().timeIntervalSince(last) > Self.resumeWithin {
            r.end = last
            d.removeObject(forKey: Self.activeKey)
            do { try context.save() } catch { NSLog("Orbeat: closing stale session failed: \(error)") }
            return
        }
        NSLog("Orbeat: resuming session \(id) after relaunch, \(s.samples.count) samples")
        resume(s)
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
        guard active != nil, case .running? = clock else { return }
        elapsed = clock!.elapsed()
        if let last = active!.samples.last, elapsed - last.t < 0.95 { return }
        let live = m.hasData && m.isFresh
        let s = Session.Sample(t: elapsed, bpm: live ? m.bpm : nil,
                               watts: m.displayWatts, rpm: m.displayCadence, kmh: m.displaySpeedKmh)
        if s.bpm != nil || s.watts != nil { active!.samples.append(s) }
        if uiVisible { objectWillChange.send() }
        if Date().timeIntervalSince(savedAt) >= Self.checkpointEvery { checkpoint() }
    }

    private func save() {
        do { try context.save() } catch { NSLog("Orbeat: session save failed: \(error)") }
        reload()
    }

    private func reload() {
        let all = FetchDescriptor<SessionRecord>(sortBy: [SortDescriptor(\.start, order: .reverse)])
        past = ((try? context.fetch(all)) ?? []).map(\.session)
        // The running session goes up on its own clock (checkpoint), not on every save.
        if RideUpload.auto { RideUpload.run(past.filter { $0.id != active?.id }) }
    }

    /// Retry unsent rides now, e.g. after the backend settings changed.
    func upload(report: ((String) -> Void)? = nil) {
        RideUpload.run(past.filter { $0.id != active?.id } + (active.map { [$0] } ?? []), report: report)
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
