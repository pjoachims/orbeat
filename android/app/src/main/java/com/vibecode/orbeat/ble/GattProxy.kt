package com.vibecode.orbeat.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import java.util.UUID

/**
 * Sensor sharing: every service the hub discovers upstream is re-published
 * 1:1 on a local GATT server. Downstream clients (Zwift, a bike computer)
 * see the same UUIDs, properties and bytes as on the sensor itself — reads,
 * writes, notifications and indications all forward raw.
 *
 * One source per characteristic UUID (latest mirrored wins), same as the
 * hub's one-slot-per-type policy.
 *
 * Android limits vs. the Apple build: the advertisement carries no local
 * name ("Orbeat") — Android only offers the phone's own Bluetooth name, so
 * clients list the phone; and only 16-bit service UUIDs are advertised.
 */
@SuppressLint("MissingPermission")
class GattProxy(private val ctx: Context) {
    var onLog: ((Map<String, Any?>) -> Unit)? = null
    /** A downstream client wrote through us (char UUID, bytes) — after forwarding. */
    var onDownstreamWrite: ((UUID, ByteArray) -> Unit)? = null

    private val bt = ctx.getSystemService(BluetoothManager::class.java)
    private val prefs = ctx.getSharedPreferences("orbeat", Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private var server: BluetoothGattServer? = null
    private var bluetoothOn = false

    /** Mirrored service by UUID, and which upstream connection it came from. */
    private val services = mutableMapOf<UUID, BluetoothGattService>()
    private val sources = mutableMapOf<UUID, Conn>()
    /** Char UUID → upstream (connection, characteristic) / downstream mirror. */
    private val upstream = mutableMapOf<UUID, Pair<Conn, BluetoothGattCharacteristic>>()
    private val mirrors = mutableMapOf<UUID, BluetoothGattCharacteristic>()

    private class Read(val device: BluetoothDevice, val requestId: Int, val offset: Int)
    /** Downstream reads waiting for the upstream value, FIFO per char. */
    private val pendingReads = mutableMapOf<UUID, MutableList<Read>>()
    /** Downstream device → chars it enabled notifications/indications on. */
    private val subscribers = mutableMapOf<BluetoothDevice, MutableSet<UUID>>()
    /** Android allows one notification in flight per device (until onNotificationSent). */
    private val inFlight = mutableSetOf<BluetoothDevice>()
    /** Latest value per device and char that waited for the radio. Latest wins. */
    private val backlog = mutableMapOf<BluetoothDevice, LinkedHashMap<UUID, ByteArray>>()
    /** addService is async and one at a time: the next waits for onServiceAdded. */
    private val adds = ArrayDeque<BluetoothGattService>()
    private var adding = false

    /** Hardware can advertise as a peripheral at all. */
    val available: Boolean get() = bt?.adapter?.isMultipleAdvertisementSupported == true

    /** Sensor sharing on/off, persisted. */
    var enabled = prefs.getBoolean("rebroadcast", false)
        set(v) {
            prefs.edit().putBoolean("rebroadcast", v).apply()
            if (v == field) return
            field = v
            sync()
        }

    /** Adapter on/off (from the hub). */
    fun bluetooth(on: Boolean) { bluetoothOn = on; sync() }

    /** Open the server while sharing is on and the radio is up; close it otherwise. */
    private fun sync() {
        if (enabled && bluetoothOn && available) {
            if (server == null) {
                server = bt.openGattServer(ctx, callback)
                services.values.forEach(::add)   // mirrored before sharing was turned on
            }
            advertise()
        } else {
            server?.let {
                bt?.adapter?.bluetoothLeAdvertiser?.stopAdvertising(advertiseCallback)
                it.close()
            }
            server = null
            adds.clear(); adding = false
            pendingReads.clear(); subscribers.clear(); inFlight.clear(); backlog.clear()
        }
    }

    private fun add(svc: BluetoothGattService) {
        adds.addLast(svc)
        nextAdd()
    }

    private fun nextAdd() {
        val s = server ?: return
        while (!adding) {
            val svc = adds.removeFirstOrNull() ?: return
            adding = s.addService(svc)
        }
    }

    // MARK: Upstream → mirror table

    private val mirrorable = BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_WRITE or
        BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or BluetoothGattCharacteristic.PROPERTY_NOTIFY or
        BluetoothGattCharacteristic.PROPERTY_INDICATE

    /** (Re)publish an upstream service once its characteristics are known. */
    fun mirror(service: BluetoothGattService, conn: Conn) {
        val svc = BluetoothGattService(service.uuid, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        for (ch in service.characteristics) {
            val props = ch.properties and mirrorable
            if (props == 0) continue
            val readable = BluetoothGattCharacteristic.PROPERTY_READ or BluetoothGattCharacteristic.PROPERTY_NOTIFY or
                BluetoothGattCharacteristic.PROPERTY_INDICATE
            val writable = BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE
            var perms = 0
            if (props and readable != 0) perms = perms or BluetoothGattCharacteristic.PERMISSION_READ
            if (props and writable != 0) perms = perms or BluetoothGattCharacteristic.PERMISSION_WRITE
            val m = BluetoothGattCharacteristic(ch.uuid, props, perms)
            // CoreBluetooth adds the CCCD itself; Android's server needs it explicitly.
            if (props and (BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0) {
                m.addDescriptor(BluetoothGattDescriptor(CCCD,
                    BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
            }
            svc.addCharacteristic(m)
            upstream[ch.uuid] = conn to ch
            mirrors[ch.uuid] = m
        }
        if (svc.characteristics.isEmpty()) return
        // Swap just this service: dropping all would cut every other subscription.
        services[service.uuid]?.let { remove(it) }
        services[service.uuid] = svc
        sources[service.uuid] = conn
        if (server != null) add(svc)
        advertise()
    }

    private fun remove(svc: BluetoothGattService) {
        if (!adds.remove(svc)) server?.removeService(svc)
    }

    /** Upstream gone: withdraw everything it backed. */
    fun unmirror(conn: Conn) {
        for ((uuid, c) in sources.toList()) if (c === conn) {
            services.remove(uuid)?.let(::remove)
            sources.remove(uuid)
        }
        // Sweep by owner, not by service: a char UUID may since have been
        // re-mirrored from another connection.
        for ((uuid, up) in upstream.toList()) if (up.first === conn) {
            upstream.remove(uuid); mirrors.remove(uuid)
            backlog.values.forEach { it.remove(uuid) }
            fail(uuid)
        }
        advertise()
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartFailure(code: Int) { onLog?.invoke(mapOf("src" to "ble", "ev" to "proxyAdvertiseFailed", "code" to code)) }
    }

    /** Re-advertise the mirrored 16-bit UUIDs; 128-bit ones are discoverable once connected. */
    private fun advertise() {
        server ?: return
        val adv = bt?.adapter?.bluetoothLeAdvertiser ?: return
        adv.stopAdvertising(advertiseCallback)
        val short = services.keys.filter { it.toString().endsWith("-0000-1000-8000-00805f9b34fb") }.sorted()
        if (short.isEmpty()) return
        val data = AdvertiseData.Builder().setIncludeDeviceName(false)
        short.forEach { data.addServiceUuid(ParcelUuid(it)) }
        adv.startAdvertising(
            AdvertiseSettings.Builder().setConnectable(true)
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM).build(),
            data.build(),
            AdvertiseData.Builder().setIncludeDeviceName(true).build(),   // phone's name, in the scan response
            advertiseCallback)
    }

    private fun fail(uuid: UUID) {
        for (r in pendingReads.remove(uuid).orEmpty()) server?.sendResponse(r.device, r.requestId, BluetoothGatt.GATT_FAILURE, 0, null)
    }

    // MARK: Upstream traffic → downstream

    /** Notification, indication or read result (null = read failed) from the sensor. */
    fun upstreamRead(conn: Conn, ch: BluetoothGattCharacteristic, value: ByteArray?) {
        if (upstream[ch.uuid]?.first !== conn) return   // not the source we mirror
        if (value == null) fail(ch.uuid) else push(ch.uuid, value)
    }

    /** Deliver a value for a mirrored char downstream (answers pending reads, notifies subscribers). */
    fun push(uuid: UUID, data: ByteArray) {
        val s = server ?: return
        mirrors[uuid] ?: return
        for (r in pendingReads.remove(uuid).orEmpty()) {
            s.sendResponse(r.device, r.requestId, BluetoothGatt.GATT_SUCCESS, r.offset,
                if (data.size > r.offset) data.copyOfRange(r.offset, data.size) else ByteArray(0))
        }
        for ((device, chars) in subscribers) if (uuid in chars) {
            if (device in inFlight) backlog.getOrPut(device) { LinkedHashMap() }[uuid] = data
            else notify(device, uuid, data)
        }
    }

    private fun notify(device: BluetoothDevice, uuid: UUID, data: ByteArray) {
        val m = mirrors[uuid] ?: return
        val indicateOnly = m.has(BluetoothGattCharacteristic.PROPERTY_INDICATE) && !m.has(BluetoothGattCharacteristic.PROPERTY_NOTIFY)
        val rc = server?.notifyCharacteristicChanged(device, m, indicateOnly, data)
        if (rc == BluetoothGatt.GATT_SUCCESS) inFlight.add(device)
        else onLog?.invoke(mapOf("src" to "ble", "ev" to "proxyNotifyFailed", "char" to uuid.toString(), "rc" to rc))
    }

    // MARK: Downstream → upstream (callbacks arrive on a binder thread; hop to main)

    private val callback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            main.post {
                onLog?.invoke(mapOf("src" to "ble", "ev" to "proxyClient", "connected" to (newState == BluetoothProfile.STATE_CONNECTED)))
                if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    subscribers.remove(device); inFlight.remove(device); backlog.remove(device)
                    pendingReads.values.forEach { reads -> reads.removeAll { it.device == device } }
                }
            }
        }

        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            main.post {
                onLog?.invoke(mapOf("src" to "ble", "ev" to "proxyService", "uuid" to service.uuid.toString(), "status" to status))
                adding = false
                nextAdd()
            }
        }

        override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, ch: BluetoothGattCharacteristic) {
            main.post {
                val up = upstream[ch.uuid]
                if (up == null) server?.sendResponse(device, requestId, BluetoothGatt.GATT_FAILURE, 0, null)
                else {
                    pendingReads.getOrPut(ch.uuid) { mutableListOf() }.add(Read(device, requestId, offset))
                    up.first.read(up.second)
                }
            }
        }

        override fun onCharacteristicWriteRequest(device: BluetoothDevice, requestId: Int, ch: BluetoothGattCharacteristic,
                                                  preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?) {
            main.post {
                val up = upstream[ch.uuid]
                // ponytail: no prepared (long) writes — no sensor command needs them
                if (up == null || value == null || preparedWrite || offset != 0) {
                    if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_WRITE_NOT_PERMITTED, 0, null)
                    return@post
                }
                onLog?.invoke(mapOf("src" to "ble", "ev" to "proxyWrite", "char" to ch.uuid.toString(), "raw" to value.joinToString("") { "%02x".format(it) }))
                up.first.write(up.second, value)
                onDownstreamWrite?.invoke(ch.uuid, value)
                // ponytail: ATT success once forwarded, not once the sensor acks
                if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        override fun onDescriptorWriteRequest(device: BluetoothDevice, requestId: Int, d: BluetoothGattDescriptor,
                                              preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray?) {
            main.post {
                val uuid = d.characteristic.uuid
                if (d.uuid == CCCD && value != null) {
                    val on = !value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)
                    onLog?.invoke(mapOf("src" to "ble", "ev" to "proxySubscribe", "char" to uuid.toString(), "on" to on))
                    val chars = subscribers.getOrPut(device) { mutableSetOf() }
                    if (on) {
                        chars.add(uuid)
                        upstream[uuid]?.let { (c, ch) -> c.subscribe(ch) }
                        // ponytail: never unsubscribes upstream — the hub wants the stream anyway
                    } else chars.remove(uuid)
                }
                if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
            }
        }

        override fun onDescriptorReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, d: BluetoothGattDescriptor) {
            main.post {
                val on = subscribers[device]?.contains(d.characteristic.uuid) == true
                server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0,
                    if (on) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)
            }
        }

        /** Radio took the last notification: send the newest waiting one. */
        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            main.post {
                inFlight.remove(device)
                val q = backlog[device] ?: return@post
                val (uuid, data) = q.entries.firstOrNull()?.toPair() ?: return@post
                q.remove(uuid)
                notify(device, uuid, data)
            }
        }
    }
}
