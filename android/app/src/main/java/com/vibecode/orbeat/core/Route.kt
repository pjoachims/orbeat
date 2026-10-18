package com.vibecode.orbeat.core

import org.xml.sax.Attributes
import org.xml.sax.helpers.DefaultHandler
import javax.xml.parsers.SAXParserFactory
import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * A route to ride in sim: elevation over distance, from a GPX file. The ride
 * advances along it at road-model speed and the trainer follows its grade.
 */
data class Route(
    val name: String,
    /** Metres from the start, strictly increasing; `ele` is metres above sea level. */
    val dist: List<Double>,
    val ele: List<Double>,
) {
    val length: Double get() = dist.lastOrNull() ?: 0.0

    /** Terrain grade at `d` metres, in TrainerMode's 0.01 % units. */
    fun grade(d: Double): Int {
        val lo = max(0.0, d - WINDOW / 2)
        val hi = min(length, d + WINDOW / 2)
        if (hi - lo < 1) return 0
        val g = ((elevation(hi) - elevation(lo)) / (hi - lo) * 10_000).rounded()
        return g.coerceIn(TrainerMode.gradeRange.first, TrainerMode.gradeRange.last)
    }

    /** Linear interpolation between points, clamped to the ends. */
    fun elevation(d: Double): Double {
        if (dist.isEmpty()) return 0.0
        val last = dist.size - 1
        if (d <= 0) return ele[0]
        if (d >= length) return ele[last]
        var lo = 0; var hi = last   // binary search: dist[lo] <= d < dist[hi]
        while (hi - lo > 1) {
            val mid = (lo + hi) / 2
            if (dist[mid] <= d) lo = mid else hi = mid
        }
        val t = (d - dist[lo]) / (dist[hi] - dist[lo])
        return ele[lo] + t * (ele[hi] - ele[lo])
    }

    /** Total climb in metres, on the same 100 m scale as the grade. */
    val climb: Double get() {
        var sum = 0.0
        var d = 0.0
        while (d < length) {
            sum += max(0.0, elevation(min(length, d + WINDOW)) - elevation(d))
            d += WINDOW
        }
        return sum
    }

    companion object {
        /** Grade window: GPX elevation is noisy point to point; 100 m is what a rider feels. */
        const val WINDOW = 100.0

        /** GPX 1.1 track (trkpt) or route (rtept) points with <ele>. null without elevation. */
        fun gpx(data: ByteArray, fallback: String): Route? {
            val p = GpxHandler()
            try {
                SAXParserFactory.newInstance().newSAXParser().parse(data.inputStream(), p)
            } catch (e: Exception) {
                return null
            }
            val firstEle = p.points.firstOrNull { it.ele != null }?.ele
            if (p.points.size < 2 || firstEle == null) return null
            val dist = mutableListOf<Double>()
            val ele = mutableListOf<Double>()
            var prev: Pt? = null
            var d = 0.0
            var lastEle: Double = firstEle
            for (pt in p.points) {
                prev?.let { d += haversine(it, pt) }
                prev = pt
                lastEle = pt.ele ?: lastEle   // a point without <ele> keeps the previous one
                if (dist.isNotEmpty() && d - dist.last() < 5) continue   // duplicates out, dense tracks thinned
                dist.add(d)
                ele.add(lastEle)
            }
            if (dist.size < 2) return null
            return Route(p.name ?: fallback, dist, ele)
        }

        private fun haversine(a: Pt, b: Pt): Double {
            val r = 6_371_000.0
            val rad = Math.PI / 180
            val dLat = (b.lat - a.lat) * rad
            val dLon = (b.lon - a.lon) * rad
            val h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * rad) * cos(b.lat * rad) * sin(dLon / 2) * sin(dLon / 2)
            return 2 * r * asin(min(1.0, sqrt(h)))
        }
    }
}

private class Pt(val lat: Double, val lon: Double, var ele: Double? = null)

private class GpxHandler : DefaultHandler() {
    val points = mutableListOf<Pt>()
    var name: String? = null
    private val text = StringBuilder()
    private var inPoint = false
    private var inWpt = false   // a waypoint's <ele>/<name> isn't ours

    private fun local(qName: String, localName: String) = localName.ifEmpty { qName.substringAfter(':') }

    override fun startElement(uri: String?, localName: String, qName: String, a: Attributes) {
        text.setLength(0)
        val el = local(qName, localName)
        if (el == "wpt") inWpt = true
        if (el == "trkpt" || el == "rtept") {
            val lat = a.getValue("lat")?.toDoubleOrNull()
            val lon = a.getValue("lon")?.toDoubleOrNull()
            if (lat != null && lon != null) {
                points.add(Pt(lat, lon))
                inPoint = true
            }
        }
    }

    override fun characters(ch: CharArray, start: Int, length: Int) { text.appendRange(ch, start, start + length) }

    override fun endElement(uri: String?, localName: String, qName: String) {
        val el = local(qName, localName)
        val t = text.toString().trim()
        if (el == "trkpt" || el == "rtept") inPoint = false
        if (el == "wpt") inWpt = false
        if (el == "ele" && inPoint) t.toDoubleOrNull()?.let { points.last().ele = it }
        // first name before any point: the track's
        if (el == "name" && !inPoint && !inWpt && name == null && points.isEmpty() && t.isNotEmpty()) name = t
    }
}
