import Foundation

/// Erg packet decoders (BLE Cycling Power + FTMS Indoor Bike) and the heart-rate
/// parser, against hand-built byte vectors.
struct ErgsTests {
    static func run() {
        // MARK: HeartRateParser

        let hr1 = HeartRateParser.parse([0x01, 0x48, 0x00], device: "Polar")!   // flags bit0 → UInt16 bpm
        check("hr uint16 bpm", hr1.bpm == 72 && hr1.device == "Polar", "\(hr1)")

        let hr2 = HeartRateParser.parse([0x00, 0x46], device: nil)!             // default UInt8 bpm
        check("hr uint8 bpm", hr2.bpm == 70, "\(hr2)")

        let rr = HeartRateParser.parse([0x10, 60, 0xE8, 0x03, 0x00], device: nil)!
        // RR u16 LE 1000/1024 s → 977 ms; trailing single byte ignored
        check("hr rr intervals", rr.rrMs == [977], "\(rr)")

        let kj = HeartRateParser.parse([0x08, 50, 0x39, 0x05], device: nil)!    // kj = 1337
        check("hr energy kj", kj.kj == 1337, "\(kj)")

        check("hr truncated → nil", HeartRateParser.parse([0x01, 0x48], device: nil) == nil)
        check("hr empty → nil", HeartRateParser.parse([], device: nil) == nil)

        let contact = HeartRateParser.parse([0x04, 60], device: nil)!
        check("hr contact flag", contact.contact == false, "\(contact)")

        // MARK: CyclingPowerParser

        let p = CyclingPowerParser()
        func powerPacket(watts: Int, wheelRevs: UInt32, wheelT: UInt16,
                         crankRevs: UInt16, crankT: UInt16) -> [UInt8] {
            var b: [UInt8] = [0x30, 0x00]                       // flags: wheel + crank present
            let w = UInt16(bitPattern: Int16(watts))
            b += [UInt8(w & 0xFF), UInt8(w >> 8)]
            b += [UInt8(wheelRevs & 0xFF), UInt8((wheelRevs >> 8) & 0xFF),
                  UInt8((wheelRevs >> 16) & 0xFF), UInt8((wheelRevs >> 24) & 0xFF)]
            b += [UInt8(wheelT & 0xFF), UInt8(wheelT >> 8)]
            b += [UInt8(crankRevs & 0xFF), UInt8(crankRevs >> 8)]
            b += [UInt8(crankT & 0xFF), UInt8(crankT >> 8)]
            return b
        }

        let first = p.parse(powerPacket(watts: 250, wheelRevs: 1000, wheelT: 2048,
                                        crankRevs: 500, crankT: 1024), device: "KICKR")!
        check("pwr first packet no deltas", first.kmh == nil && first.rpm == nil, "\(first)")
        check("pwr watts", first.watts == 250)

        let second = p.parse(powerPacket(watts: 260, wheelRevs: 1010, wheelT: 4096,
                                         crankRevs: 502, crankT: 2048), device: "KICKR")!
        // Δwheel=10 revs over dt=1 s, circ 2.105 m → 75.78 km/h
        let expectKmh = 10 * 2.105 / 1.0 * 3.6
        check("pwr speed math", abs(second.kmh! - expectKmh) < 0.01, "\(second.kmh!) vs \(expectKmh)")
        // Δcrank=2 revs over dt=1 s → 120 rpm
        check("pwr cadence math", second.rpm == 120, "\(second.rpm!)")
        check("pwr raw counters", second.crankRevs == 502 && second.wheelEvt == 4096, "\(second)")
        check("pwr device name", second.device == "KICKR")
        check("pwr reading maps cadence", second.reading.cadence == 120 && second.reading.watts == 260)

        let stopped = p.parse(powerPacket(watts: 5, wheelRevs: 1010, wheelT: 4096,
                                          crankRevs: 502, crankT: 2048), device: nil)!
        check("pwr stopped → zero", stopped.kmh == 0 && stopped.rpm == 0, "\(stopped)")

        // Trainer counters reset to 0 mid-link (standby): delta wraps to ~65k revs.
        let wrapped = p.parse(powerPacket(watts: 5, wheelRevs: 0, wheelT: 6144,
                                          crankRevs: 0, crankT: 3072), device: nil)!
        check("pwr counter reset → no sample", wrapped.kmh == nil && wrapped.rpm == nil, "\(wrapped)")
        let resumed = p.parse(powerPacket(watts: 5, wheelRevs: 10, wheelT: 8192,
                                          crankRevs: 2, crankT: 4096), device: nil)!
        check("pwr resumes after counter reset", resumed.rpm == 120 && abs(resumed.kmh! - expectKmh) < 0.01, "\(resumed)")

        p.reset()
        let afterReset = p.parse(powerPacket(watts: 5, wheelRevs: 1010, wheelT: 4096,
                                             crankRevs: 502, crankT: 2048), device: nil)!
        check("pwr reset clears deltas", afterReset.kmh == nil && afterReset.rpm == nil)

        check("pwr truncated → nil", p.parse([0x30, 0x00, 0xFA], device: nil) == nil)

        // MARK: FtmsIndoorBikeParser

        // Real-world capture (nRF-verified): flags 0x0244 → speed +
        // cadence(bit2) + power(bit6) + HR(bit9).
        let ftms1 = FtmsIndoorBikeParser.parse([0x44, 0x02, 0x52, 0x03, 0x5A, 0x00, 0x08, 0x00, 0x00],
                                               device: "FTMS")!
        check("ftms speed/cadence/power", ftms1.kmh == 8.50 && ftms1.rpm == 45 && ftms1.watts == 8, "\(ftms1)")

        // flags = more-data(bit0) + cadence(bit2) → no speed field, no power field.
        let ftms2 = FtmsIndoorBikeParser.parse([0x05, 0x00, 0xB4, 0x00], device: nil)!
        check("ftms cadence only, watts nil",
              ftms2.rpm == 90 && ftms2.watts == nil && ftms2.kmh == nil, "\(ftms2)")
        check("ftms no watts → no reading", ftms2.reading == nil)

        // Distance (bit4, u24) and resistance (bit5) must be skipped correctly:
        // flags = bit2|bit4|bit5|bit6 = 0x0074.
        var fb: [UInt8] = [0x74, 0x00]
        fb += [0x64, 0x00]          // speed 1.00 km/h
        fb += [0x78, 0x00]          // cadence 120/2 = 60 rpm
        fb += [0x10, 0x00, 0x00]    // distance 16 m
        fb += [0x32, 0x00]          // resistance 50
        fb += [0xC4, 0x01]          // power 452 W
        let ftms3 = FtmsIndoorBikeParser.parse(fb, device: nil)!
        check("ftms optional-field skipping",
              ftms3.kmh == 1.0 && ftms3.rpm == 60 && ftms3.watts == 452, "\(ftms3)")

        check("ftms truncated", FtmsIndoorBikeParser.parse([0x44], device: nil) == nil)

        // MARK: FtmsMachineStatus (0x2ADA)

        check("status sim grade", FtmsMachineStatus.parse([0x12, 0, 0, 0x20, 0x03, 0, 0]) == .sim(grade: 800))
        check("status sim negative grade",
              FtmsMachineStatus.parse([0x12, 0, 0, 0x9C, 0xFF, 0, 0]) == .sim(grade: -100))
        check("status target power", FtmsMachineStatus.parse([0x08, 0xC8, 0x00]) == .erg(targetWatts: 200))
        check("status resistance u8", FtmsMachineStatus.parse([0x07, 0x64]) == .resistance(percent: 10))
        check("status resistance s16", FtmsMachineStatus.parse([0x07, 0x90, 0x01]) == .resistance(percent: 40))
        check("status other opcode ignored", FtmsMachineStatus.parse([0x04, 0x00]) == nil)
        check("status truncated", FtmsMachineStatus.parse([0x12, 0, 0]) == nil
              && FtmsMachineStatus.parse([0x08]) == nil)

        // MARK: bridge: control-point write → mode → synthesized status
        for m in [TrainerMode.sim(grade: -100), .sim(grade: 800), .erg(targetWatts: 250), .resistance(percent: 40)] {
            check("status encode round-trips \(m)", FtmsMachineStatus.parse(FtmsMachineStatus.encode(m)) == m)
        }
        check("control sim write", FtmsControlFrame.parse([0x11, 0, 0, 0x20, 0x03, 0, 0]) == .sim(grade: 800))
        check("control erg write", FtmsControlFrame.parse([0x05, 0xC8, 0x00]) == .erg(targetWatts: 200))
        check("control resistance write", FtmsControlFrame.parse([0x04, 0x90, 0x01]) == .resistance(percent: 40))
        check("control request/start ignored", FtmsControlFrame.parse([0x00]) == nil && FtmsControlFrame.parse([0x07]) == nil)
    }
}
