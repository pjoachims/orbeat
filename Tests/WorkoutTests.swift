import Foundation

enum WorkoutTests {
    static func run() {
        let zwo = """
        <workout_file><name>Over-Unders</name><workout>
          <Warmup Duration="60" PowerLow="0.5" PowerHigh="1.0"/>
          <SteadyState Duration="30" Power="0.8"/>
          <FreeRide Duration="600"/>
          <IntervalsT Repeat="2" OnDuration="10" OffDuration="20" OnPower="1.2" OffPower="0.4"/>
          <Cooldown Duration="0" PowerLow="0.6" PowerHigh="0.3"/>
        </workout></workout_file>
        """
        guard let z = Workout.parse(Data(zwo.utf8), ext: "zwo", name: "file", ftp: 200) else { return check("zwo parses", false) }
        check("zwo name", z.name == "Over-Unders", z.name)
        check("zwo length (FreeRide skipped)", z.length == 150, "\(z.length)")
        check("warmup ramps in FTP fraction", z.watts(at: 0) == 100 && z.watts(at: 30) == 150, "\(z.steps)")
        check("steady state", z.watts(at: 75) == 160)
        check("intervals repeat", z.watts(at: 95) == 240 && z.watts(at: 110) == 80 && z.watts(at: 125) == 240)
        check("finished is nil", z.watts(at: 150) == nil)

        let erg = """
        [COURSE HEADER]
        DESCRIPTION = 4x8 minutes at 105 percent
        UNITS = ENGLISH
        MINUTES WATTS
        [END COURSE HEADER]
        [COURSE DATA]
        0.00\t100
        1.00\t100
        1.00\t250
        2.00\t300
        [END COURSE DATA]
        """
        let e = Workout.parse(Data(erg.utf8), ext: "erg", name: "Sweet", ftp: 999)
        check("erg absolute watts, step + ramp", e?.watts(at: 30) == 100 && e?.watts(at: 60) == 250 && e?.watts(at: 90) == 275,
              "\(String(describing: e))")
        check("erg name from file", e?.name == "Sweet" && e?.length == 120)
        let mrc = erg.replacingOccurrences(of: "MINUTES WATTS", with: "MINUTES PERCENT")
        check("mrc percent of FTP", Workout.parse(Data(mrc.utf8), ext: "mrc", name: "x", ftp: 200)?.watts(at: 30) == 200)
        check("no data is nil", Workout.parse(Data("[COURSE DATA]\n[END COURSE DATA]".utf8), ext: "erg", name: "x", ftp: 200) == nil)
        check("zero-length only is nil", Workout.parse(Data(#"<workout_file><workout><SteadyState Duration="0" Power="1"/></workout></workout_file>"#.utf8), ext: "zwo", name: "x", ftp: 200) == nil)
        check("latin-1 erg loads", Workout.parse(Data(erg.utf8) + Data([0x0A, 0xE9]), ext: "erg", name: "x", ftp: 200) != nil)
        check("garbage zwo is nil", Workout.parse(Data("nope".utf8), ext: "zwo", name: "x", ftp: 200) == nil)

        // Builder: what it rides is what it exports.
        var plan = WorkoutPlan.sample
        plan.name = "A & <B>"
        let ridden = plan.workout(ftp: 250)
        check("plan expands intervals", ridden.steps.count == 9 && ridden.length == 3900, "\(ridden.steps.count) \(ridden.length)")
        check("plan watts at FTP", ridden.watts(at: 0) == 125 && ridden.watts(at: 900) == 225 && ridden.watts(at: 1500) == 138)
        let back = Workout.parse(Data(plan.zwo.utf8), ext: "zwo", name: "x", ftp: 250)
        check("plan .zwo round-trips", back == ridden, "\(String(describing: back))")
        check("plan stats", Int((plan.intensity * 200).rounded()) == 148 && plan.tss == 67, "\(plan.intensity) \(plan.tss)")
        check("TSS: 1 h at 80 % is 64", WorkoutPlan(name: "s", blocks: [.init(kind: .steady, seconds: 3600, power: 0.8)]).tss == 64)
        plan.name = "a]]>b"
        check("plan name escapes ]]>", Workout.parse(Data(plan.zwo.utf8), ext: "zwo", name: "x", ftp: 250)?.name == "a]]>b")
        check("old draft has no FTP override", (try? JSONDecoder().decode(WorkoutPlan.self, from: Data(#"{"name":"x","blocks":[]}"#.utf8)))?.ftp == nil)
        check("kind switch keeps time", plan.blocks[2].as(.steady).seconds == 2700 && plan.blocks[1].as(.ramp).seconds == 300)
    }
}
