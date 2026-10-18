package com.vibecode.orbeat.core

import org.xml.sax.Attributes
import org.xml.sax.helpers.DefaultHandler
import javax.xml.parsers.SAXParserFactory
import kotlin.math.roundToInt

/**
 * A structured workout to ride in ERG: power targets over time, from a Zwift
 * .zwo or an .erg / .mrc course file. Watts are absolute; files given in % of
 * FTP are converted when loaded.
 */
data class Workout(val name: String, val steps: List<Step>) {
    /** Target at the step's start and end; they differ on a ramp. */
    data class Step(val seconds: Double, val from: Int, val to: Int)

    val length: Double get() = steps.sumOf { it.seconds }

    /** ERG target `t` seconds in, ramps interpolated; null once finished. */
    fun watts(t: Double): Int? {
        var start = 0.0
        for (s in steps) {
            if (t < start + s.seconds) return (s.from + (s.to - s.from) * (t - start) / s.seconds).roundToInt()
            start += s.seconds
        }
        return null
    }

    companion object {
        val extensions = setOf("zwo", "erg", "mrc")

        /** null when the file has no targets to ride. */
        fun parse(data: ByteArray, ext: String, name: String, ftp: Int): Workout? {
            val w = if (ext == "zwo") zwo(data, name, ftp) else course(data.decodeToString(), name, ftp)
            return w?.takeIf { it.length > 0 }
        }

        /** Zwift workout XML; power is a fraction of FTP. */
        private fun zwo(data: ByteArray, name: String, ftp: Int): Workout? {
            val p = ZwoHandler(ftp.toDouble())
            try {
                SAXParserFactory.newInstance().newSAXParser().parse(data.inputStream(), p)
            } catch (e: Exception) {
                return null
            }
            return Workout(p.name ?: name, p.steps)
        }

        /** .erg (watts) / .mrc (% of FTP): `minutes value` points between [COURSE DATA] markers, joined linearly. */
        private fun course(text: String, name: String, ftp: Int): Workout {
            var percent = false
            var inData = false
            val points = mutableListOf<Pair<Double, Double>>()
            for (line in text.lines()) {
                val u = line.uppercase()
                if ("[COURSE DATA]" in u) { inData = true; continue }
                if ("[END COURSE DATA]" in u) { inData = false; continue }
                if (!inData) {
                    // the column line only: a DESCRIPTION may say "minutes at 105 percent"
                    if (u.trim().split(Regex("\\s+")) == listOf("MINUTES", "PERCENT")) percent = true
                    continue
                }
                val f = line.trim().split(Regex("\\s+")).mapNotNull { it.toDoubleOrNull() }
                if (f.size >= 2) points.add(f[0] to f[1])
            }
            fun watts(v: Double) = (if (percent) v / 100 * ftp else v).roundToInt()
            val steps = points.zipWithNext().mapNotNull { (a, b) ->
                if (b.first > a.first) Step((b.first - a.first) * 60, watts(a.second), watts(b.second)) else null
            }
            return Workout(name, steps)
        }
    }
}

private class ZwoHandler(val ftp: Double) : DefaultHandler() {
    val steps = mutableListOf<Workout.Step>()
    var name: String? = null
    private val text = StringBuilder()

    override fun startElement(uri: String?, localName: String, qName: String, a: Attributes) {
        text.setLength(0)
        fun num(k: String) = a.getValue(k)?.toDoubleOrNull()
        fun w(f: Double) = (f * ftp).roundToInt()
        // ponytail: FreeRide / MaxEffort skipped (no ERG target); hold-previous if anyone misses them
        when (localName.ifEmpty { qName }) {
            "SteadyState" -> {
                val d = num("Duration"); val p = num("Power") ?: num("PowerLow")
                if (d != null && p != null) steps.add(Workout.Step(d, w(p), w(p)))
            }
            "Warmup", "Cooldown", "Ramp" -> {
                val d = num("Duration"); val lo = num("PowerLow"); val hi = num("PowerHigh")
                if (d != null && lo != null && hi != null) steps.add(Workout.Step(d, w(lo), w(hi)))
            }
            "IntervalsT" -> {
                val n = num("Repeat"); val on = num("OnDuration"); val off = num("OffDuration")
                val pOn = num("OnPower") ?: num("PowerOnLow"); val pOff = num("OffPower") ?: num("PowerOffLow")
                if (n != null && on != null && off != null && pOn != null && pOff != null) repeat(n.toInt()) {
                    steps.add(Workout.Step(on, w(pOn), w(pOn)))
                    steps.add(Workout.Step(off, w(pOff), w(pOff)))
                }
            }
        }
    }

    override fun characters(ch: CharArray, start: Int, length: Int) { text.appendRange(ch, start, start + length) }

    override fun endElement(uri: String?, localName: String, qName: String) {
        val t = text.toString().trim()
        if (localName.ifEmpty { qName } == "name" && name == null && t.isNotEmpty()) name = t
    }
}
