package com.vibecode.orbeat.model

import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyStore
import java.time.Instant
import java.util.concurrent.Executors
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Posts finished sessions to the user's own health backend (any server
 * `POST <url>/rides`), same contract as the Apple apps' RideUpload. Asks the
 * backend first (`GET <url>/rides`) and sends only sessions it lacks or holds
 * with another sample count (a resumed ride). Unsent ones wait for the next
 * session, launch or Upload tap.
 * ponytail: no retry timer; a failed upload waits for the next trigger.
 */
class RideUpload(private val prefs: SharedPreferences) {
    /** One run at a time; a queued run re-asks the backend, so it never double-sends. */
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    var url: String
        get() = prefs.getString(URL_KEY, "")!!.trim().trimEnd('/')
        set(v) = prefs.edit().putString(URL_KEY, v).apply()
    /** Upload on every finished session and launch; off = only the Upload button. */
    var auto: Boolean
        get() = prefs.getBoolean(AUTO_KEY, true)
        set(v) = prefs.edit().putBoolean(AUTO_KEY, v).apply()

    /** Bearer token, AES-encrypted with a Keystore key: it reads and writes the user's health data. */
    var token: String
        get() = runCatching {
            val (iv, data) = prefs.getString(TOKEN_KEY, null)!!.split(":").map { Base64.decode(it, Base64.NO_WRAP) }
            val c = Cipher.getInstance(AES).apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv)) }
            String(c.doFinal(data))
        }.getOrDefault("")
        set(v) {
            val t = v.trim()
            if (t.isEmpty()) return prefs.edit().remove(TOKEN_KEY).apply()
            // A broken Keystore (OEM, restored backup) must not crash Settings; the token just isn't kept.
            runCatching {
                val c = Cipher.getInstance(AES).apply { init(Cipher.ENCRYPT_MODE, key()) }
                val enc = listOf(c.iv, c.doFinal(t.toByteArray())).joinToString(":") { Base64.encodeToString(it, Base64.NO_WRAP) }
                prefs.edit().putString(TOKEN_KEY, enc).apply()
            }.onFailure { Log.w("Orbeat", "ride upload token not saved", it) }
        }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    /**
     * Sends one session at a time; stops at the first failure except a 400 (a body
     * the backend will never take), skipped so it can't block the rest.
     * `report` gets a one-line result on the main thread.
     */
    fun run(sessions: List<Session>, report: ((String) -> Unit)? = null) {
        val base = url; val token = token
        if (token.isEmpty() || !base.startsWith("http")) return done(report, "Set URL and token first")
        worker.execute {
            val held = runCatching { held(base, token) }.getOrElse { return@execute done(report, "Failed: ${why(it)}") }
            val todo = todo(sessions, held)
            if (todo.isEmpty()) return@execute done(report, "All ${sessions.size} rides on backend")
            var sent = 0
            for (s in todo) {
                val status = runCatching { request("POST", "$base/rides", token, body(s).toString()).first }
                    .getOrElse { return@execute done(report, "Failed: ${why(it)} ($sent of ${todo.size} sent)") }
                when (status) {
                    200 -> sent++
                    400 -> Log.w("Orbeat", "ride ${s.id} rejected by backend, skipped")
                    else -> return@execute done(report, "Failed: HTTP $status ($sent of ${todo.size} sent)")
                }
            }
            done(report, "Sent $sent of ${todo.size} rides")
        }
    }

    /** Checks URL + token against the backend; reports its ride count. */
    fun test(report: (String) -> Unit) {
        val base = url; val token = token
        if (token.isEmpty() || !base.startsWith("http")) return done(report, "Set URL and token first")
        worker.execute {
            done(report, runCatching { "Connected · ${held(base, token).size} rides on backend" }.getOrElse { "Failed: ${why(it)}" })
        }
    }

    private fun done(report: ((String) -> Unit)?, msg: String) {
        if (msg.startsWith("Failed")) Log.w("Orbeat", "ride upload: $msg")
        report?.let { main.post { it(msg) } }
    }

    private fun why(e: Throwable) = e.message ?: e.javaClass.simpleName

    /** The backend's rides as id → sample count. */
    private fun held(base: String, token: String): Map<String, Int> {
        val (status, text) = request("GET", "$base/rides", token, null)
        if (status != 200) error("HTTP $status")
        return parseHeld(text)
    }

    private fun request(method: String, url: String, token: String, body: String?): Pair<Int, String> {
        val c = URL(url).openConnection() as HttpURLConnection
        try {
            c.requestMethod = method
            c.connectTimeout = 15_000; c.readTimeout = 30_000
            c.setRequestProperty("Authorization", "Bearer $token")
            if (body != null) {
                c.doOutput = true
                c.setRequestProperty("Content-Type", "application/json")
                c.outputStream.use { it.write(body.toByteArray()) }
            }
            val status = c.responseCode
            val text = (if (status < 400) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
            return status to text
        } finally { c.disconnect() }
    }

    companion object {
        const val URL_KEY = "rideUploadURL"
        const val AUTO_KEY = "rideUploadAuto"
        private const val TOKEN_KEY = "rideUploadToken"
        private const val ALIAS = "orbeat-ride-upload"
        private const val AES = "AES/GCM/NoPadding"

        /** The Session JSON the Apple apps send: dates as ISO 8601 (whole seconds), nulls left out. */
        fun body(s: Session): JSONObject = SessionStore.encode(s).put("start", iso(s.start)).put("end", s.end?.let(::iso))

        private fun iso(t: Double) = Instant.ofEpochSecond(kotlin.math.floor(t).toLong()).toString()

        fun parseHeld(json: String): Map<String, Int> {
            val a = JSONArray(json)
            return (0 until a.length()).map { a.getJSONObject(it) }.filter { it.has("id") && it.has("samples") }
                .associate { it.getString("id") to it.getInt("samples") }
        }

        fun todo(sessions: List<Session>, held: Map<String, Int>) = sessions.filter { held[it.id] != it.samples.size }
    }
}
