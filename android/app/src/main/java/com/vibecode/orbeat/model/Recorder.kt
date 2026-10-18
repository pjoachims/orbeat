package com.vibecode.orbeat.model

import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.vibecode.orbeat.core.LogWriting
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * DuckDB logging: when on, appends one JSON line per BLE packet to
 * orbeat.jsonl — same format as the Apple apps (sorted keys, "t" ISO-8601 ms).
 * ponytail: single append-only file, add rotation if it ever gets big.
 */
class Recorder(val file: File, private val prefs: SharedPreferences) : LogWriting {
    private var writer: FileWriter? = null
    private val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSXXX", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }

    private var _recording by mutableStateOf(false)
    var recording: Boolean
        get() = _recording
        set(v) {
            _recording = v
            prefs.edit().putBoolean("duckdbLog", v).apply()
            writer?.close(); writer = null
            if (v) writer = FileWriter(file, true)
        }

    init { if (prefs.getBoolean("duckdbLog", false)) recording = true }

    override fun log(fields: Map<String, Any?>) {
        val w = writer ?: return
        val o = JSONObject()
        (fields + ("t" to iso.format(Date()))).toSortedMap().forEach { (k, v) ->
            o.put(k, if (v is Collection<*>) JSONArray(v) else v)
        }
        w.write(o.toString()); w.write("\n"); w.flush()
    }
}
