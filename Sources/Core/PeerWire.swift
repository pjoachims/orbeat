import Foundation

/// What one Orbeat tells the other over the peer link: only readings from
/// sensors it is connected to DIRECTLY, never what it learned from the peer,
/// so nothing can echo back and forth.
struct PeerState: Codable, Equatable {
    var bpm: Int?
    var hrSource: String?
    var watts: Int?
    var cadence: Int?
    var kmh: Double?
    var powerSource: String?
    /// Trainer target, set only while this device controls a trainer.
    var trainer: TrainerMode?
    /// Session this device is recording, if any: its clock's virtual start
    /// while running, or the frozen elapsed seconds while paused.
    var recordingSince: Date?
    var recordingPaused: TimeInterval?
    /// Rider settings of the trainer owner, so the other side shows and edits them.
    var rider: Rider?

    enum CodingKeys: String, CodingKey {
        case bpm = "b", hrSource = "hs", watts = "w", cadence = "c", kmh = "k",
             powerSource = "ps", trainer = "t", recordingSince = "r", recordingPaused = "rp", rider = "rd"
    }

    var recording: SessionClock? {
        get { recordingPaused.map(SessionClock.paused) ?? recordingSince.map(SessionClock.running) }
        set {
            switch newValue {
            case .running(let since)?: recordingSince = since; recordingPaused = nil
            case .paused(let e)?: recordingSince = nil; recordingPaused = e
            case nil: recordingSince = nil; recordingPaused = nil
            }
        }
    }
}

/// A recording session's clock. Running counts from a virtual start (real
/// start shifted by paused time); paused holds the elapsed seconds.
enum SessionClock: Equatable {
    case running(since: Date)
    case paused(elapsed: TimeInterval)

    func elapsed(at now: Date = Date()) -> TimeInterval {
        switch self {
        case .running(let since): return now.timeIntervalSince(since)
        case .paused(let e): return e
        }
    }

    var isPaused: Bool { if case .paused = self { return true } else { return false } }
    func pausing(at now: Date = Date()) -> SessionClock { .paused(elapsed: elapsed(at: now)) }
    func resuming(at now: Date = Date()) -> SessionClock { .running(since: now.addingTimeInterval(-elapsed(at: now))) }
}

/// Remote control: sent to the device that owns the trainer / the session.
enum PeerCommand: Equatable {
    case step(HandlebarInput)
    case setTrainer(TrainerMode)
    /// Rider settings changed on the device that doesn't own the trainer.
    case setRider(Rider)
    /// New terrain grade (route mode); the owner keeps its own gear.
    case setGrade(Int)
    /// Stop the session the receiver is recording (sessions record where started).
    case stopSession
    /// Pause (true) or resume (false) the receiver's session.
    case pauseSession(Bool)
}

enum PeerMessage: Equatable {
    case state(PeerState)
    case command(PeerCommand)
}

/// One message per characteristic value, compact JSON. Must stay under the
/// ~180-byte ATT payload Apple devices negotiate (checked in tests).
enum PeerWire {
    private struct Envelope: Codable {
        var s: PeerState?
        var step: Int?          // +1 up, -1 down
        var set: TrainerMode?
        var rider: Rider?
        var grade: Int?
        var stop: Bool?
        var pause: Bool?
    }

    static func encode(_ m: PeerMessage) -> Data {
        var e = Envelope()
        switch m {
        case .state(let s): e.s = s
        case .command(.step(let i)): e.step = i == .shiftUp ? 1 : -1
        case .command(.setTrainer(let t)): e.set = t
        case .command(.setRider(let r)): e.rider = r
        case .command(.setGrade(let g)): e.grade = g
        case .command(.stopSession): e.stop = true
        case .command(.pauseSession(let p)): e.pause = p
        }
        return (try? encoder.encode(e)) ?? Data()
    }

    static func decode(_ data: Data) -> PeerMessage? {
        guard let e = try? decoder.decode(Envelope.self, from: data) else { return nil }
        if let s = e.s { return .state(s) }
        if let s = e.step { return .command(.step(s > 0 ? .shiftUp : .shiftDown)) }
        if let t = e.set { return .command(.setTrainer(t)) }
        if let r = e.rider { return .command(.setRider(r)) }
        if let g = e.grade { return .command(.setGrade(g)) }
        if e.stop == true { return .command(.stopSession) }
        if let p = e.pause { return .command(.pauseSession(p)) }
        return nil
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

/// Compact wire form: {"erg":200} / {"res":40} / {"sim":150,"g":12}.
extension TrainerMode: Codable {
    private enum K: String, CodingKey { case erg, res, sim, g }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        if let w = try c.decodeIfPresent(Int.self, forKey: .erg) { self = .erg(targetWatts: w) }
        else if let p = try c.decodeIfPresent(Int.self, forKey: .res) { self = .resistance(percent: p) }
        else { self = .sim(grade: try c.decode(Int.self, forKey: .sim),
                           gear: try c.decodeIfPresent(Int.self, forKey: .g) ?? TrainerMode.neutralGear) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .erg(let w): try c.encode(w, forKey: .erg)
        case .resistance(let p): try c.encode(p, forKey: .res)
        case .sim(let g, let gear): try c.encode(g, forKey: .sim); try c.encode(gear, forKey: .g)
        }
    }
}
