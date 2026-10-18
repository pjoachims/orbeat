package com.vibecode.orbeat.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.ParcelUuid
import com.vibecode.orbeat.core.PeerMessage
import com.vibecode.orbeat.core.PeerWire
import java.util.UUID

/**
 * Orbeat ↔ Orbeat link, phone side: finds the Mac's peer service by UUID,
 * stays connected, rescans on loss. Messages are `PeerWire` frames: Mac →
 * phone by notification, phone → Mac by write.
 *
 * Known limit: with sensor sharing on, the Mac pushes the 128-bit peer UUID
 * into Apple's overflow area, which Android can't see — the link then only
 * comes up while the Mac shares nothing.
 * ponytail: no saved-address reconnect; the scan finds the Mac either way.
 */
@SuppressLint("MissingPermission")
class PeerClient(private val ctx: Context) : Conn.Listener {
    companion object {
        const val PEER_LABEL = "Mac"
        val SERVICE: UUID = UUID.fromString("6F726265-0001-4F52-4245-41542D4C4E4B")
        val TO_CLIENT: UUID = UUID.fromString("6F726265-0002-4F52-4245-41542D4C4E4B")
        val TO_SERVER: UUID = UUID.fromString("6F726265-0003-4F52-4245-41542D4C4E4B")
    }

    var onMessage: ((PeerMessage) -> Unit)? = null
    var onConnected: ((Boolean) -> Unit)? = null
    var onLog: ((Map<String, Any?>) -> Unit)? = null
    var connected = false
        private set(v) { if (v != field) { field = v; onConnected?.invoke(v) } }

    private val scanner get() = ctx.getSystemService(BluetoothManager::class.java)?.adapter?.bluetoothLeScanner
    private var peer: Conn? = null
    private var rx: BluetoothGattCharacteristic? = null
    private var scanning = false

    fun send(m: PeerMessage) {
        val p = peer ?: return
        val ch = rx ?: return
        if (!connected) return
        val data = PeerWire.encode(m)
        // Commands must arrive; state is resent every second anyway.
        if (m is PeerMessage.Command) p.write(ch, data, withResponse = true)
        else if (p.idle) p.write(ch, data, withResponse = false)
    }

    /** Adapter on/off (from the hub). */
    fun bluetooth(on: Boolean) {
        if (on) { search(); return }
        scanning = false
        peer?.close(); peer = null; rx = null
        connected = false
    }

    private fun search() {
        if (scanning || peer != null) return
        val s = scanner ?: return
        scanning = true
        s.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()),
            ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build(), scanCallback)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(type: Int, r: ScanResult) {
            if (peer != null) return
            onLog?.invoke(mapOf("src" to "peer", "ev" to "found", "name" to (r.scanRecord?.deviceName ?: "?")))
            scanner?.stopScan(this)
            scanning = false
            peer = Conn(ctx, r.device, this@PeerClient)
        }
        override fun onScanFailed(code: Int) { scanning = false; onLog?.invoke(mapOf("src" to "peer", "ev" to "scanFailed", "code" to code)) }
    }

    override fun onConnected(c: Conn) {
        onLog?.invoke(mapOf("src" to "peer", "ev" to "connected"))
        c.requestMtu(517)   // PeerWire frames are up to ~180 bytes; the default MTU carries 20
        c.discover()
    }

    override fun onDisconnected(c: Conn, wasConnected: Boolean) {
        if (c !== peer) return
        onLog?.invoke(mapOf("src" to "peer", "ev" to if (wasConnected) "disconnected" else "failToConnect"))
        peer = null; rx = null
        connected = false
        search()
    }

    override fun onServices(c: Conn) {
        connected = false
        rx = null
        // Connected to a Mac whose Orbeat isn't running: wait for Service Changed.
        val svc = c.gatt.getService(SERVICE) ?: return
        rx = svc.getCharacteristic(TO_SERVER)
        svc.getCharacteristic(TO_CLIENT)?.let(c::subscribe)
        c.enqueue { connected = rx != null; false }   // runs once the subscribe is acked
    }

    override fun onValue(c: Conn, ch: BluetoothGattCharacteristic, value: ByteArray) {
        if (ch.uuid != TO_CLIENT) return
        PeerWire.decode(value)?.let { onMessage?.invoke(it) }
    }
}
