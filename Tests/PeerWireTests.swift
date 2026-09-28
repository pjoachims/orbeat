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
            .command(.stopSession),
            .command(.pauseSession(true)),
            .command(.pauseSession(false)),
            .state(PeerState(recordingPaused: 3725.5)),
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

        let t0 = Date(timeIntervalSince1970: 1_000)
        let run = SessionClock.running(since: t0)
        let paused = run.pausing(at: t0.addingTimeInterval(60))
        check("clock pause freezes", paused == .paused(elapsed: 60) && paused.elapsed(at: t0.addingTimeInterval(500)) == 60)
        check("clock resume continues", paused.resuming(at: t0.addingTimeInterval(500)).elapsed(at: t0.addingTimeInterval(510)) == 70)
        var st = PeerState(); st.recording = paused
        check("peer clock paused", st.recording == paused && st.recordingSince == nil)
        st.recording = run
        check("peer clock running", st.recording == run && st.recordingPaused == nil)
    }
}
