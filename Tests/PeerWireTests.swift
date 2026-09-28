import Foundation

enum PeerWireTests {
    static func run() {
        let full = PeerState(bpm: 187, hrSource: "Polar H10 A1B2C3D4", watts: 1234, cadence: 110,
                             kmh: 45.123456789, powerSource: "KICKR CORE 5A3F",
                             trainer: .resistance(percent: 100),
                             recordingSince: Date(timeIntervalSince1970: 1_790_000_000.123))
        let messages: [PeerMessage] = [
            .state(full),
            .state(PeerState()),
            .command(.step(.shiftUp)),
            .command(.step(.shiftDown)),
            .command(.setTrainer(.erg(targetWatts: 250))),
            .command(.setTrainer(.sim(grade: -500))),
            .command(.startSession),
            .command(.stopSession),
        ]
        for m in messages {
            let data = PeerWire.encode(m)
            check("peer roundtrip \(m)", PeerWire.decode(data) == m,
                  String(decoding: data, as: UTF8.self))
        }
        let size = PeerWire.encode(.state(full)).count
        check("peer state fits one ATT payload (\(size) B)", size <= 180)
        check("peer garbage ignored", PeerWire.decode(Data("nope".utf8)) == nil)
        check("peer empty envelope ignored", PeerWire.decode(Data("{}".utf8)) == nil)
    }
}
