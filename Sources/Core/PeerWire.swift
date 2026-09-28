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
    /// Start of the session this device is recording, if any.
    var recordingSince: Date?

    enum CodingKeys: String, CodingKey {
        case bpm = "b", hrSource = "hs", watts = "w", cadence = "c", kmh = "k",
             powerSource = "ps", trainer = "t", recordingSince = "r"
    }
}

/// Remote control: sent to the device that owns the trainer / the session.
enum PeerCommand: Equatable {
    case step(HandlebarInput)
    case setTrainer(TrainerMode)
    /// Stop the session the receiver is recording (sessions record where started).
    case stopSession
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
        var stop: Bool?
    }

    static func encode(_ m: PeerMessage) -> Data {
        var e = Envelope()
        switch m {
        case .state(let s): e.s = s
        case .command(.step(let i)): e.step = i == .shiftUp ? 1 : -1
        case .command(.setTrainer(let t)): e.set = t
        case .command(.stopSession): e.stop = true
        }
        return (try? encoder.encode(e)) ?? Data()
    }

    static func decode(_ data: Data) -> PeerMessage? {
        guard let e = try? decoder.decode(Envelope.self, from: data) else { return nil }
        if let s = e.s { return .state(s) }
        if let s = e.step { return .command(.step(s > 0 ? .shiftUp : .shiftDown)) }
        if let t = e.set { return .command(.setTrainer(t)) }
        if e.stop == true { return .command(.stopSession) }
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

/// Compact wire form: {"erg":200} / {"res":40} / {"sim":150}.
extension TrainerMode: Codable {
    private enum K: String, CodingKey { case erg, res, sim }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        if let w = try c.decodeIfPresent(Int.self, forKey: .erg) { self = .erg(targetWatts: w) }
        else if let p = try c.decodeIfPresent(Int.self, forKey: .res) { self = .resistance(percent: p) }
        else { self = .sim(grade: try c.decode(Int.self, forKey: .sim)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .erg(let w): try c.encode(w, forKey: .erg)
        case .resistance(let p): try c.encode(p, forKey: .res)
        case .sim(let g): try c.encode(g, forKey: .sim)
        }
    }
}
