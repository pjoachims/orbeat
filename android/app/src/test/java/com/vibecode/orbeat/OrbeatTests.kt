package com.vibecode.orbeat

import com.vibecode.orbeat.core.*
import com.vibecode.orbeat.drivers.*
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.abs
import kotlin.math.roundToInt

/** Port of the Swift Tests folder: same vectors, same expectations. */
class OrbeatTests {
    private fun b(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    @Test fun heartRate() {
        val hr1 = HeartRateParser.parse(b(0x01, 0x48, 0x00), "Polar")!!
        assertTrue(hr1.bpm == 72 && hr1.device == "Polar")
        assertEquals(70, HeartRateParser.parse(b(0x00, 0x46), null)!!.bpm)
        assertEquals(listOf(977), HeartRateParser.parse(b(0x10, 60, 0xE8, 0x03, 0x00), null)!!.rrMs)
        assertEquals(1337, HeartRateParser.parse(b(0x08, 50, 0x39, 0x05), null)!!.kj)
        assertNull(HeartRateParser.parse(b(0x01, 0x48), null))
        assertNull(HeartRateParser.parse(b(), null))
        assertEquals(false, HeartRateParser.parse(b(0x04, 60), null)!!.contact)
    }

    private fun powerPacket(watts: Int, wheelRevs: Long, wheelT: Int, crankRevs: Int, crankT: Int) = b(
        0x30, 0x00, watts and 0xFF, (watts shr 8) and 0xFF,
        (wheelRevs and 0xFF).toInt(), ((wheelRevs shr 8) and 0xFF).toInt(), ((wheelRevs shr 16) and 0xFF).toInt(), ((wheelRevs shr 24) and 0xFF).toInt(),
        wheelT and 0xFF, wheelT shr 8, crankRevs and 0xFF, crankRevs shr 8, crankT and 0xFF, crankT shr 8,
    )

    @Test fun cyclingPower() {
        val p = CyclingPowerParser()
        val first = p.parse(powerPacket(250, 1000, 2048, 500, 1024), "KICKR")!!
        assertTrue(first.kmh == null && first.rpm == null)
        assertEquals(250, first.watts)
        val second = p.parse(powerPacket(260, 1010, 4096, 502, 2048), "KICKR")!!
        val expectKmh = 10 * 2.105 / 1.0 * 3.6
        assertEquals(expectKmh, second.kmh!!, 0.01)
        assertEquals(120, second.rpm)
        assertTrue(second.crankRevs == 502 && second.wheelEvt == 4096)
        assertEquals("KICKR", second.device)
        assertTrue(second.reading.cadence == 120 && second.reading.watts == 260)
        val stopped = p.parse(powerPacket(5, 1010, 4096, 502, 2048), null)!!
        assertTrue(stopped.kmh == 0.0 && stopped.rpm == 0)
        val wrapped = p.parse(powerPacket(5, 0, 6144, 0, 3072), null)!!
        assertTrue("$wrapped", wrapped.kmh == null && wrapped.rpm == null)
        val resumed = p.parse(powerPacket(5, 10, 8192, 2, 4096), null)!!
        assertTrue(resumed.rpm == 120 && abs(resumed.kmh!! - expectKmh) < 0.01)
        p.reset()
        val afterReset = p.parse(powerPacket(5, 1010, 4096, 502, 2048), null)!!
        assertTrue(afterReset.kmh == null && afterReset.rpm == null)
        assertNull(p.parse(b(0x30, 0x00, 0xFA), null))
    }

    @Test fun ftmsIndoorBike() {
        val f1 = FtmsIndoorBikeParser.parse(b(0x44, 0x02, 0x52, 0x03, 0x5A, 0x00, 0x08, 0x00, 0x00), "FTMS")!!
        assertTrue("$f1", f1.kmh == 8.50 && f1.rpm == 45 && f1.watts == 8)
        val f2 = FtmsIndoorBikeParser.parse(b(0x05, 0x00, 0xB4, 0x00), null)!!
        assertTrue(f2.rpm == 90 && f2.watts == null && f2.kmh == null)
        assertNull(f2.reading)
        val f3 = FtmsIndoorBikeParser.parse(b(0x74, 0x00, 0x64, 0x00, 0x78, 0x00, 0x10, 0x00, 0x00, 0x32, 0x00, 0xC4, 0x01), null)!!
        assertTrue("$f3", f3.kmh == 1.0 && f3.rpm == 60 && f3.watts == 452)
        assertNull(FtmsIndoorBikeParser.parse(b(0x44), null))
    }

    @Test fun machineStatusAndControl() {
        assertEquals(TrainerMode.Sim(800), FtmsMachineStatus.parse(b(0x12, 0, 0, 0x20, 0x03, 0, 0)))
        assertEquals(TrainerMode.Sim(-100), FtmsMachineStatus.parse(b(0x12, 0, 0, 0x9C, 0xFF, 0, 0)))
        assertEquals(TrainerMode.Erg(200), FtmsMachineStatus.parse(b(0x08, 0xC8, 0x00)))
        assertEquals(TrainerMode.Resistance(10), FtmsMachineStatus.parse(b(0x07, 0x64)))
        assertEquals(TrainerMode.Resistance(40), FtmsMachineStatus.parse(b(0x07, 0x90, 0x01)))
        assertNull(FtmsMachineStatus.parse(b(0x04, 0x00)))
        assertTrue(FtmsMachineStatus.parse(b(0x12, 0, 0)) == null && FtmsMachineStatus.parse(b(0x08)) == null)
        for (m in listOf(TrainerMode.Erg(250), TrainerMode.Resistance(40)))
            assertEquals(m, FtmsMachineStatus.parse(FtmsMachineStatus.encode(m, Rider())))
        assertArrayEquals(b(0x12) + TrainerMode.Sim(500, 1).simParams(Rider())!!.bytes, FtmsMachineStatus.encode(TrainerMode.Sim(500, 1), Rider()))
        assertEquals(TrainerMode.Sim(800), FtmsControlFrame.parse(b(0x11, 0, 0, 0x20, 0x03, 0, 0)))
        assertEquals(TrainerMode.Erg(200), FtmsControlFrame.parse(b(0x05, 0xC8, 0x00)))
        assertEquals(TrainerMode.Resistance(40), FtmsControlFrame.parse(b(0x04, 0x90, 0x01)))
        assertTrue(FtmsControlFrame.parse(b(0x00)) == null && FtmsControlFrame.parse(b(0x07)) == null)
    }

    @Test fun trainerMode() {
        assertEquals(TrainerMode.Erg(600), TrainerMode.Erg(700).clamped)
        assertEquals(TrainerMode.Erg(30), TrainerMode.Erg(5).clamped)
        assertEquals(TrainerMode.Erg(205), TrainerMode.Erg(200).steppedUp)
        assertEquals(TrainerMode.Erg(600), TrainerMode.Erg(600).steppedUp)
        assertEquals(TrainerMode.Erg(30), TrainerMode.Erg(30).steppedDown)
        assertEquals(TrainerMode.Sim(300, 11), TrainerMode.Sim(300, 12).steppedDown)
        assertEquals(TrainerMode.Sim(-500), TrainerMode.Sim(-600).clamped)
        assertEquals(TrainerMode.Sim(1500, 24), TrainerMode.Sim(1600, 24).steppedUp)
        assertEquals(TrainerMode.Sim(0, 1), TrainerMode.Sim(0, 1).steppedDown)
        assertEquals(400, TrainerMode.Sim(800).sentGrade(50))
        assertTrue(TrainerMode.Sim(-1000).sentGrade(100) == -500 && TrainerMode.Sim(-1000).sentGrade(50) == -250)
        assertEquals(0, TrainerMode.Sim(1500).sentGrade(0))
        assertEquals(Rider(40, 25, 100), Rider(-1, 99, 1_000_000).clamped)
        val full = Rider(80, 8, 100)
        val one = TrainerMode.Sim(500).simParams(full)!!
        assertEquals(SimParams(494, 40, 49), one)
        assertArrayEquals(b(0, 0, 0xEE, 0x01, 40, 49), one.bytes)
        fun force(g: Int, gear: Int): Double {
            val p = TrainerMode.Sim(g, gear).simParams(full)!!
            val v = 1.5 * TrainerMode.trainerRatio * 2.105
            return full.massKg * 9.81 * (p.grade + p.crr) / 10_000 + p.cw / 100.0 * v * v
        }
        for (g in listOf(-500, -200, 0, 500, 1500)) {
            val f = TrainerMode.gearRange.map { maxOf(0.0, force(g, it)) }
            assertTrue("shift up never easier at $g: $f", f.zipWithNext().all { (a, c) -> a <= c } && f.last() > 0)
        }
        assertTrue(force(-500, 1) < 0)
        assertEquals(255, TrainerMode.Sim(0, 24).simParams(full)!!.cw)
        assertTrue(TrainerMode.Erg(200).simParams(full) == null && ZwiftHub.frames(TrainerMode.Erg(200), full) == null)

        assertArrayEquals(b(0x04, 0x22, 0x0b, 0x08, 0x00, 0x10, 0xda, 0x02, 0x18, 0xec, 0x27, 0x20, 0x90, 0x03), ZwiftHub.simulation(173))
        assertArrayEquals(b(0x10, 0x01), ZwiftHub.simulation(-1).copyOfRange(5, 7))
        val qz = Rider(85, 8, 50)
        assertArrayEquals(b(0x04, 0x2a, 0x0a, 0x10, 0xc0, 0xbb, 0x01, 0x20, 0xa0, 0x06, 0x28, 0xb4, 0x42), ZwiftHub.physical(2.4, qz))
        val f = ZwiftHub.frames(TrainerMode.Sim(800, 24), qz)!!
        assertArrayEquals(ZwiftHub.simulation(400), f[0])
        assertArrayEquals(ZwiftHub.physical(5.49, qz), f[1])
        assertEquals(TrainerMode.Resistance(100), TrainerMode.Resistance(95).steppedUp)
        assertEquals("ERG · 200 W", TrainerMode.Erg(200).label)
        assertEquals("1.5 % · Gear 8", TrainerMode.Sim(150, 8).label)
        assertEquals("Resistance · 40 %", TrainerMode.Resistance(40).label)
        assertTrue(TrainerMode.Erg(200).stepLabel == "+5 W" && TrainerMode.Sim(150).stepLabel == "+1 gear")
        assertEquals(TrainerMode.Erg(175), TrainerMode.Erg(120).resumed(175, 250, 7))
        assertEquals(TrainerMode.Sim(250, 7), TrainerMode.Sim(0).resumed(175, 250, 7))
    }

    private fun frame(map: Long): ByteArray {
        var v = map
        val payload = mutableListOf<Int>()
        do {
            var byte = (v and 0x7F).toInt()
            v = v ushr 7
            if (v != 0L) byte = byte or 0x80
            payload.add(byte)
        } while (v != 0L)
        return b(0x23, 0x08, *payload.toIntArray())
    }

    @Test fun zwiftButtons() {
        val c = ZwiftRideController()
        assertNull(c.handle(frame(0xFFFFFFFF)))
        val up = c.handle(frame(0xFFFFFEFF))!!
        assertTrue("$up", up.newlyPressed == setOf(256L) && up.pressed == listOf("leftShiftUp"))
        assertNull(c.handle(frame(0xFFFFFEFF)))
        val down = c.handle(frame(0xFFFFFDFF))!!
        assertTrue(down.newlyPressed.any { it and ZwiftButtonFrame.SHIFT_DOWN != 0L }
            && down.newlyPressed.none { it and ZwiftButtonFrame.SHIFT_UP != 0L } && down.pressed == listOf("leftShiftDown"))
        val fresh = ZwiftRideController()
        fresh.handle(frame(0xFFFFFFFF))
        val both = fresh.handle(frame(0xFFFFCCFF))!!
        assertTrue(both.newlyPressed.any { it and ZwiftButtonFrame.SHIFT_UP != 0L }
            && both.newlyPressed.any { it and ZwiftButtonFrame.SHIFT_DOWN != 0L } && both.newlyPressed.size == 4)
        c.reset()
        assertTrue(c.handle(frame(0xFFFFFEFF))!!.newlyPressed.any { it and ZwiftButtonFrame.SHIFT_UP != 0L })
        val tail = c.handle(frame(0xFFFFFCFF) + b(0x10, 0x02, 0xAA, 0xBB))!!
        assertTrue(tail.newlyPressed.any { it and ZwiftButtonFrame.SHIFT_DOWN != 0L })
        assertNull(c.handle(b(0x24, 0x08, 0x00)))
        assertNull(c.handle(b()))
    }

    @Test fun peerWire() {
        val full = PeerState(187, "Polar H10 A1B2C3D4", 1234, 110, 45.123456789, "KICKR CORE 5A3F",
            TrainerMode.Resistance(100), SessionClock.Running(1_790_000_000.123), Rider(150, 25, 100))
        val messages = listOf(
            PeerMessage.State(full), PeerMessage.State(PeerState()),
            PeerMessage.Command(PeerCommand.Step(HandlebarInput.ShiftUp)),
            PeerMessage.Command(PeerCommand.Step(HandlebarInput.ShiftDown)),
            PeerMessage.Command(PeerCommand.SetTrainer(TrainerMode.Erg(250))),
            PeerMessage.Command(PeerCommand.SetTrainer(TrainerMode.Sim(-500))),
            PeerMessage.Command(PeerCommand.SetTrainer(TrainerMode.Sim(800, 3))),
            PeerMessage.Command(PeerCommand.SetRider(Rider(80, 8, 75))),
            PeerMessage.Command(PeerCommand.SetGrade(-250)),
            PeerMessage.Command(PeerCommand.StopSession),
            PeerMessage.Command(PeerCommand.PauseSession(true)),
            PeerMessage.Command(PeerCommand.PauseSession(false)),
            PeerMessage.State(PeerState(recording = SessionClock.Paused(3725.5))),
        )
        for (m in messages) assertEquals(String(PeerWire.encode(m)), m, PeerWire.decode(PeerWire.encode(m)))
        val size = PeerWire.encode(PeerMessage.State(full)).size
        assertTrue("$size B", size <= 180)
        assertNull(PeerWire.decode("nope".toByteArray()))
        assertNull(PeerWire.decode("{}".toByteArray()))
        // Swift-encoded state decodes (keys, ints, seconds since 1970).
        assertEquals(PeerMessage.State(PeerState(bpm = 120, trainer = TrainerMode.Sim(150, 12), recording = SessionClock.Running(1_000.5))),
            PeerWire.decode("""{"s":{"b":120,"t":{"sim":150,"g":12},"r":1000.5}}""".toByteArray()))

        val run = SessionClock.Running(1_000.0)
        val paused = run.pausing(1_060.0)
        assertTrue(paused == SessionClock.Paused(60.0) && paused.elapsed(1_500.0) == 60.0)
        assertEquals(70.0, paused.resuming(1_500.0).elapsed(1_510.0), 0.0)
    }

    @Test fun curve() {
        val pts = (0 until 10).map { Curve.Point(it.toDouble(), if (it % 2 == 0) 100.0 else 200.0) }
        assertEquals(pts, Curve.smooth(pts, 0.0))
        val s = Curve.smooth(pts, 2.0)
        assertEquals(500 / 3.0, s[4].v, 1e-9)
        assertEquals(150.0, s[0].v, 1e-9)
        val gap = listOf(Curve.Point(0.0, 100.0), Curve.Point(60.0, 300.0))
        assertEquals(gap, Curve.smooth(gap, 10.0))
        val long = (0 until 3601).map { Curve.Point(it.toDouble(), 1.0) }
        val thin = Curve.thin(long)
        assertTrue(thin.size <= 601 && thin.last() == long.last())
        assertEquals(pts, Curve.thin(pts))
    }

    @Test fun roadSpeed() {
        assertEquals(30.0, RoadSpeed.kmh(140), 1.5)
        assertEquals(0.0, RoadSpeed.kmh(0), 0.0)
        assertTrue(RoadSpeed.kmh(200, 8.0) < 15)
        assertTrue(RoadSpeed.kmh(100, -3.0) > RoadSpeed.kmh(100))
        assertTrue(RoadSpeed.kmh(250) > RoadSpeed.kmh(200))
        assertTrue(RoadSpeed.kmh(250, 6.0, 100.0) < RoadSpeed.kmh(250, 6.0, 70.0))
    }

    @Test fun route() {
        val gpx = """
            <?xml version="1.0"?>
            <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
              <wpt lat="47.1" lon="11.1"><ele>9999</ele><name>Hut</name></wpt>
              <trk><name>Test Climb</name><trkseg>
                <trkpt lat="47.0" lon="11.0"><ele>500</ele></trkpt>
                <trkpt lat="47.0" lon="11.0"><ele>500</ele></trkpt>
                <trkpt lat="47.004496" lon="11.0"></trkpt>
                <trkpt lat="47.008993" lon="11.0"><ele>550</ele></trkpt>
                <trkpt lat="47.017986" lon="11.0"><ele>550</ele></trkpt>
              </trkseg></trk>
            </gpx>
        """.trimIndent()
        val r = Route.gpx(gpx.toByteArray(), "file")!!
        assertEquals("Test Climb", r.name)
        assertEquals(4, r.dist.size)
        assertEquals(2000.0, r.length, 5.0)
        assertEquals(500.0, r.ele[1], 0.0)
        assertEquals(0, r.grade(250.0))
        assertEquals(1000, r.grade(750.0))
        assertEquals(0, r.grade(1600.0))
        assertTrue(r.grade(1000.0) in 0..1000)
        assertEquals(50.0, r.climb, 1.0)
        assertTrue(r.elevation(-10.0) == 500.0 && r.elevation(9e9) == 550.0)
        assertEquals(TrainerMode.gradeRange.last, Route("wall", listOf(0.0, 100.0), listOf(0.0, 40.0)).grade(50.0))
        assertNull(Route.gpx("""<gpx><trk><trkseg><trkpt lat="1" lon="1"/><trkpt lat="1.01" lon="1"/></trkseg></trk></gpx>""".toByteArray(), "x"))
        assertEquals("fallback", Route.gpx("""<gpx><rte><rtept lat="1" lon="1"><ele>1</ele></rtept><rtept lat="1.01" lon="1"><ele>2</ele></rtept></rte></gpx>""".toByteArray(), "fallback")?.name)
        assertNull(Route.gpx("nope".toByteArray(), "x"))
    }

    @Test fun workout() {
        val zwo = """
            <workout_file><name>Over-Unders</name><workout>
              <Warmup Duration="60" PowerLow="0.5" PowerHigh="1.0"/>
              <SteadyState Duration="30" Power="0.8"/>
              <FreeRide Duration="600"/>
              <IntervalsT Repeat="2" OnDuration="10" OffDuration="20" OnPower="1.2" OffPower="0.4"/>
              <Cooldown Duration="0" PowerLow="0.6" PowerHigh="0.3"/>
            </workout></workout_file>
        """.trimIndent()
        val z = Workout.parse(zwo.toByteArray(), "zwo", "file", 200)!!
        assertEquals("Over-Unders", z.name)
        assertEquals(150.0, z.length, 0.0)   // FreeRide skipped
        assertEquals(listOf(100, 150, 160, 240, 80, 240, null), listOf(0.0, 30.0, 75.0, 95.0, 110.0, 125.0, 150.0).map(z::watts))
        val erg = "[COURSE HEADER]\nDESCRIPTION = 4x8 minutes at 105 percent\nUNITS = ENGLISH\nMINUTES WATTS\n[END COURSE HEADER]\n[COURSE DATA]\n" +
            "0.00\t100\n1.00\t100\n1.00\t250\n2.00\t300\n[END COURSE DATA]\n"
        val e = Workout.parse(erg.toByteArray(), "erg", "Sweet", 999)!!
        assertEquals(listOf(100, 250, 275), listOf(30.0, 60.0, 90.0).map(e::watts))
        assertEquals("Sweet", e.name)
        assertEquals(120.0, e.length, 0.0)
        assertEquals(200, Workout.parse(erg.replace("MINUTES WATTS", "MINUTES PERCENT").toByteArray(), "mrc", "x", 200)?.watts(30.0))
        assertNull(Workout.parse("[COURSE DATA]\n[END COURSE DATA]".toByteArray(), "erg", "x", 200))
        assertNull(Workout.parse("nope".toByteArray(), "zwo", "x", 200))
        assertNull(Workout.parse("""<workout_file><workout><SteadyState Duration="0" Power="1"/></workout></workout_file>""".toByteArray(), "zwo", "x", 200))
    }

    // Builder: what it rides is what it exports.
    @Test fun workoutPlan() {
        var plan = WorkoutPlan.sample.copy(name = "A & <B>")
        val ridden = plan.workout(250)
        assertTrue("${ridden.steps.size} ${ridden.length}", ridden.steps.size == 9 && ridden.length == 3900.0)
        assertEquals(listOf(125, 225, 138), listOf(0.0, 900.0, 1500.0).map(ridden::watts))
        assertEquals(ridden, Workout.parse(plan.zwo.toByteArray(), "zwo", "x", 250))
        assertEquals(148, (plan.intensity * 200).roundToInt())
        assertEquals(67, plan.tss)
        assertEquals(64, WorkoutPlan("s", listOf(WorkoutPlan.Block(WorkoutPlan.Kind.Steady, seconds = 3600, power = 0.8))).tss)
        plan = plan.copy(name = "a]]>b")
        assertEquals("a]]>b", Workout.parse(plan.zwo.toByteArray(), "zwo", "x", 250)?.name)
        assertNull(WorkoutPlan.decode("""{"name":"x","blocks":[]}""")!!.ftp)
        assertEquals(plan.copy(ftp = 230), WorkoutPlan.decode(plan.copy(ftp = 230).json))
        assertEquals(2700, plan.blocks[2].asKind(WorkoutPlan.Kind.Steady).seconds)
        assertEquals(300, plan.blocks[1].asKind(WorkoutPlan.Kind.Ramp).seconds)
        assertEquals(listOf("a-b.zwo", "Workout.zwo", "Workout.zwo", "x.y.zwo"),
            listOf("a/b", "", " .. ", " .x.y. ").map { plan.copy(name = it).fileName })
    }
    @Test fun rideUpload() {
        val s = com.vibecode.orbeat.model.Session("A1", 1_760_000_000.7, null,
            listOf(com.vibecode.orbeat.model.Session.Sample(1.0, 120, null, 90, 30.5)))
        val b = com.vibecode.orbeat.model.RideUpload.body(s)
        assertEquals("2025-10-09T08:53:20Z", b.getString("start"))
        assertFalse(b.has("end"))
        val x = b.getJSONArray("samples").getJSONObject(0)
        assertTrue(x.getInt("bpm") == 120 && !x.has("watts") && x.getDouble("kmh") == 30.5)
        val held = com.vibecode.orbeat.model.RideUpload.parseHeld("""[{"id":"A1","samples":1},{"id":"B","samples":5},{"x":1}]""")
        assertEquals(mapOf("A1" to 1, "B" to 5), held)
        val resumed = s.copy(samples = s.samples + s.samples)
        val other = s.copy(id = "C")
        assertEquals(listOf("A1", "C"), com.vibecode.orbeat.model.RideUpload.todo(listOf(s, resumed, other), held).map { it.id })
        assertTrue(com.vibecode.orbeat.model.RideUpload.todo(listOf(s), held).isEmpty())
    }
}
