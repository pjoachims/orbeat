package com.vibecode.orbeat.ble

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.ParcelUuid
import com.vibecode.orbeat.core.HandlebarInput
import com.vibecode.orbeat.core.LogWriting
import com.vibecode.orbeat.core.Rider
import com.vibecode.orbeat.core.SensorEvent
import com.vibecode.orbeat.core.TrainerMode
import com.vibecode.orbeat.core.hex
import com.vibecode.orbeat.drivers.CyclingPowerParser
import com.vibecode.orbeat.drivers.FtmsControlFrame
import com.vibecode.orbeat.drivers.FtmsIndoorBikeParser
import com.vibecode.orbeat.drivers.FtmsMachineStatus
import com.vibecode.orbeat.drivers.HeartRateParser
import com.vibecode.orbeat.drivers.ZwiftButtonFrame
import com.vibecode.orbeat.drivers.ZwiftHub
import com.vibecode.orbeat.drivers.ZwiftRideController
import java.util.UUID

/** Standard and Zwift GATT UUIDs the hub speaks. */
object Uuids {
    val hrService = uuid16("180D")
    val hrMeasurement = uuid16("2A37")
    val powerService = uuid16("1818")
    val powerMeasurement = uuid16("2A63")
    /** FTMS Indoor Bike Data — telemetry for trainers without a Cycling Power Service. */
    val ftmsIndoorBikeData = uuid16("2AD2")
    val ftmsService = uuid16("1826")
    val controlPoint = uuid16("2AD9")
    val machineStatus = uuid16("2ADA")   // notifies target changes
    /** Original Zwift service, and the SIG-assigned FC82 newer firmware uses. */
    val zwiftServices = listOf(UUID.fromString("00000001-19CA-4651-86E5-FA29DCDD09D1"), uuid16("FC82"))
    val zwiftAsync = UUID.fromString("00000002-19CA-4651-86E5-FA29DCDD09D1")
    val zwiftSyncRx = UUID.fromString("00000003-19CA-4651-86E5-FA29DCDD09D1")
    val zwiftSyncTx = UUID.fromString("00000004-19CA-4651-86E5-FA29DCDD09D1")
    val zwiftUnknown6 = UUID.fromString("00000006-19CA-4651-86E5-FA29DCDD09D1")
    /** "RideOn" wakes the button stream. Plaintext — no key exchange for this family. */
    val rideOn = "RideOn".toByteArray()
    /**
     * Every iPhone/Mac exposes this; no sensor does. An Apple device in a sensor
     * slot is another Orbeat's share proxy — its data arrives over the peer link.
     */
    val appleContinuity: UUID = UUID.fromString("D0611E78-BBB4-4591-A5F8-487910AE4366")

    fun isButtonChar(u: UUID) = u == zwiftAsync || u == zwiftSyncTx || u == zwiftUnknown6
}

/**
 * Connects standard BLE sensors — Heart Rate (180D), Cycling Power (1818),
 * FTMS trainers (control point 2AD9) — and Zwift Ride/Play button frames.
 * Port of BLEManager: knows nothing about the UI model, logs raw packets to
 * the injected sink and reports decoded results as `SensorEvent`s.
 * Everything runs on the main thread.
 */
@SuppressLint("MissingPermission")
class BleHub(private val ctx: Context, private val logSink: LogWriting?) : Conn.Listener {
    var onEvent: ((SensorEvent) -> Unit)? = null

    data class Device(
        val bt: BluetoothDevice,
        val isPower: Boolean,
        /** A Zwift Play/Ride handlebar controller — an input device, not a sensor. */
        val isRide: Boolean = false,
        /** Advertised a standard HR/power service. False only for "show all" finds. */
        val isSensor: Boolean = true,
        val advName: String? = null,
    ) {
        val address: String get() = bt.address
        val name: String get() = advName ?: bt.name ?: "Unknown device"
    }

    /** Optional bridge mode: mirror every connected sensor as a local BLE peripheral. */
    val proxy = GattProxy(ctx)

    private val adapter: BluetoothAdapter? = ctx.getSystemService(BluetoothManager::class.java)?.adapter
    private val prefs = ctx.getSharedPreferences("orbeat", Context.MODE_PRIVATE)
    private val conns = mutableMapOf<String, Conn>()
    private var hrSlot: String? = null
    private var powerSlot: String? = null
    private var rideSlot: String? = null
    /** Everything seen while scanning, for the Equipment list. */
    val discovered = mutableListOf<Device>()
    /** Devices the user has connected before — only these auto-connect. */
    private val known = prefs.getStringSet("knownDevices", emptySet())!!.toMutableSet()

    private val powerParser = CyclingPowerParser()
    /** Devices whose power arrives via CPS; their FTMS stream is ignored. */
    private val cpsDevices = mutableSetOf<String>()
    private val buttonDecode = ZwiftRideController()
    private val trainer = Trainer()

    private fun emit(e: SensorEvent) { onEvent?.invoke(e) }
    private fun log(fields: Map<String, Any?>) { logSink?.log(fields) }
    private fun saveKnown() { prefs.edit().putStringSet("knownDevices", known.toSet()).apply() }
    private fun deviceName(addr: String): String? = discovered.firstOrNull { it.address == addr }?.name

    private val scanServices = listOf(Uuids.hrService, Uuids.powerService) + Uuids.zwiftServices
    private val discoveryServices = scanServices + listOf(Uuids.ftmsService, Uuids.appleContinuity)

    init {
        proxy.onLog = ::log
        // A downstream Orbeat set a target through us: the trainer won't tell
        // us (it only notifies the OTHER centrals), so learn it from the write.
        proxy.onDownstreamWrite = { uuid, data ->
            if (uuid == Uuids.controlPoint) FtmsControlFrame.parse(data)?.let { trainer.observed(it); emit(SensorEvent.Mode(it)) }
        }
    }

    fun isConnected(d: Device) = conns[d.address]?.connected == true
    fun isKnown(d: Device) = d.address in known

    /** Drop from auto-connect and disconnect if currently connected. */
    fun forget(d: Device) {
        known.remove(d.address); saveKnown()
        if (d.address in listOf(hrSlot, powerSlot, rideSlot)) cancel(d.address)
    }

    /** Connect a specific device, replacing the current one of the same type. */
    fun connect(d: Device) {
        val old = when {
            d.isRide -> rideSlot.also { rideSlot = d.address }
            d.isPower -> powerSlot.also { powerSlot = d.address }
            else -> hrSlot.also { hrSlot = d.address }
        }
        if (old != null && old != d.address) cancel(old)
        emit(SensorEvent.Status("Connecting ${d.name}…"))
        if (conns[d.address] == null) conns[d.address] = Conn(ctx, d.bt, this)
        known.add(d.address); saveKnown()
    }

    // MARK: Adapter lifecycle

    private var started = false

    /** Call once the Bluetooth permissions are granted. Idempotent. */
    fun start() {
        if (started) return
        val granted = listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
            .all { ctx.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        if (!granted) { emit(SensorEvent.Status("Bluetooth not authorized")); return }
        if (adapter == null) { emit(SensorEvent.Status("Bluetooth unavailable")); return }
        started = true
        ctx.registerReceiver(object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) = stateChanged()
        }, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
        stateChanged()
    }

    private fun stateChanged() {
        val on = adapter?.state == BluetoothAdapter.STATE_ON
        log(mapOf("src" to "ble", "ev" to "centralState", "state" to adapter?.state))
        proxy.bluetooth(on)
        peerStateListener?.invoke(on)
        if (on) {
            emit(SensorEvent.Status("Scanning…"))
            scan()
        } else {
            emit(SensorEvent.Status("Bluetooth off"))
            scanningAll = null
            conns.keys.toList().forEach(::cancel)
        }
    }

    /** The peer client follows the same adapter state. */
    var peerStateListener: ((Boolean) -> Unit)? = null

    // MARK: Scanning

    /** null = not scanning; else whether the scan is unfiltered. */
    private var scanningAll: Boolean? = null
    private var wantAll = false

    /** Unfiltered scan: list every nearby BLE device, not just HR/power advertisers. */
    fun setScanAll(all: Boolean) { wantAll = all; scan() }

    // ponytail: scans forever so the equipment list stays fresh; stop-when-connected if battery matters
    /**
     * Restarts only when the mode changes: Android repeats results within one
     * scan anyway (CoreBluetooth needed restarts to see a device again), and
     * throttles apps that start more than 5 scans per 30 s.
     */
    private fun scan() {
        val scanner = adapter?.takeIf { it.state == BluetoothAdapter.STATE_ON }?.bluetoothLeScanner ?: return
        if (scanningAll == wantAll) return
        if (scanningAll != null) scanner.stopScan(scanCallback)
        scanningAll = wantAll
        val filters = if (wantAll) null else scanServices.map { ScanFilter.Builder().setServiceUuid(ParcelUuid(it)).build() }
        scanner.startScan(filters, ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanCallback)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(type: Int, r: ScanResult) = found(r)
        override fun onScanFailed(code: Int) {
            log(mapOf("src" to "ble", "ev" to "scanFailed", "code" to code))
            scanningAll = null
        }
    }

    private fun found(r: ScanResult) {
        val advertised = r.scanRecord?.serviceUuids?.map { it.uuid }.orEmpty()
        val advName = r.scanRecord?.deviceName
        val name = advName ?: r.device.name
        // Another Orbeat (peer link or share proxy): never a sensor here.
        if (advName == "Orbeat" || PeerClient.SERVICE in advertised) return
        // Zwift Ride/Play advertise the service only in the scan response — fall back to the name.
        val isRide = advertised.any { it in Uuids.zwiftServices } || name?.contains("zwift", ignoreCase = true) == true
        val isPower = Uuids.powerService in advertised && Uuids.hrService !in advertised
        // Filtered scans imply a sensor even when the record omits the service list.
        val isSensor = scanningAll == false || Uuids.hrService in advertised || Uuids.powerService in advertised || isRide
        if (!isSensor && name == null) return   // skip anonymous junk in show-all
        val addr = r.device.address
        val fresh = discovered.none { it.address == addr }
        if (fresh) {
            log(mapOf("src" to "ble", "ev" to "found", "name" to (name ?: "?"), "adv" to advertised.map { it.toString() }))
            discovered.add(Device(r.device, isPower, isRide, isSensor, advName))
        }
        // Auto-connect only devices the user has connected before; new ones
        // wait in the Equipment list.
        val slotFree = if (isRide) rideSlot == null else if (isPower) powerSlot == null else hrSlot == null
        if (!isSensor || !slotFree) return
        if (addr in known) connect(Device(r.device, isPower, isRide, true, advName))
        else if (fresh) emit(SensorEvent.Status("Found ${name ?: "device"} — connect it under Equipment"))
    }

    // MARK: Connection lifecycle

    /** Close a connection and run the same cleanup as a remote disconnect. */
    private fun cancel(addr: String) {
        conns[addr]?.close()
        conns[addr]?.let { onDisconnected(it, true) }
    }

    override fun onConnected(c: Conn) {
        log(mapOf("src" to "ble", "ev" to "connected", "name" to (deviceName(c.device.address) ?: "?"),
                  "ride" to (c.device.address == rideSlot)))
        c.discover()
    }

    override fun onDisconnected(c: Conn, wasConnected: Boolean) {
        val addr = c.device.address
        if (conns[addr] !== c) return
        conns.remove(addr)
        val name = deviceName(addr) ?: "device"
        if (!wasConnected) {
            // Free the slot connect() claimed, or a dead known device blocks every other sensor forever.
            if (hrSlot == addr) hrSlot = null
            if (powerSlot == addr) powerSlot = null
            if (rideSlot == addr) rideSlot = null
            emit(SensorEvent.Status("Couldn't connect $name · rescanning…"))
            log(mapOf("src" to "ble", "ev" to "failToConnect", "name" to name))
        } else {
            if (hrSlot == addr) {
                hrSlot = null
                emit(SensorEvent.HeartLinkDown)
                emit(SensorEvent.Status("Disconnected · rescanning…"))
            }
            if (powerSlot == addr) {
                powerSlot = null
                cpsDevices.remove(addr)
                powerParser.reset()
                trainer.detach()
                emit(SensorEvent.TrainerLost)
                emit(SensorEvent.PowerLinkDown)
            }
            if (rideSlot == addr) {
                rideSlot = null
                buttonDecode.reset()
            }
            log(mapOf("src" to "ble", "ev" to "disconnected", "name" to name))
        }
        proxy.unmirror(c)
    }

    override fun onServices(c: Conn) {
        val addr = c.device.address
        val services = c.gatt.services.filter { it.uuid in discoveryServices }
        log(mapOf("src" to "ble", "ev" to "services", "name" to (deviceName(addr) ?: "?"),
                  "uuids" to c.gatt.services.map { it.uuid.toString() }))
        if (services.any { it.uuid == Uuids.appleContinuity }) {
            log(mapOf("src" to "ble", "ev" to "appleDeviceDropped", "name" to (deviceName(addr) ?: "?")))
            discovered.removeAll { it.address == addr }
            known.remove(addr); saveKnown()
            cancel(addr)
            return
        }
        services.forEach { characteristics(c, it) }
    }

    private fun characteristics(c: Conn, service: BluetoothGattService) {
        val addr = c.device.address
        val notifies = BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_INDICATE
        for (ch in service.characteristics) {
            when (ch.uuid) {
                Uuids.hrMeasurement -> {
                    c.subscribe(ch)
                    emit(SensorEvent.HeartLinkUp(deviceName(addr) ?: "BLE device"))
                }
                Uuids.powerMeasurement -> {
                    c.subscribe(ch)
                    cpsDevices.add(addr)
                    emit(SensorEvent.PowerLinkUp(deviceName(addr) ?: "Power meter"))
                }
                // CPS devices: their FTMS stream is ignored, so don't subscribe —
                // through a bridge it only competes with 2A63 for the notify queue.
                Uuids.ftmsIndoorBikeData -> if (ch.has(BluetoothGattCharacteristic.PROPERTY_NOTIFY) && addr !in cpsDevices) {
                    c.subscribe(ch)
                    emit(SensorEvent.PowerLinkUp(deviceName(addr) ?: "Trainer"))
                }
                // Only the power-slot device drives the trainer: a phone bridging HR
                // can expose an FTMS service too and would steal control.
                Uuids.controlPoint -> if (addr == powerSlot) {
                    trainer.attach(c, ch)
                    emit(SensorEvent.TrainerReady)
                }
                Uuids.machineStatus -> if (addr == powerSlot) c.subscribe(ch)
                Uuids.zwiftSyncRx -> {
                    // "RideOn" handshake starts the button stream.
                    c.write(ch, Uuids.rideOn)
                    if (addr == powerSlot) {
                        trainer.attachZwift(c, ch)   // a Zwift-Ready trainer: sim + gears go here
                        log(mapOf("src" to "ble", "ev" to "zwiftTrainer", "name" to (deviceName(addr) ?: "?")))
                    }
                }
                else -> if (Uuids.isButtonChar(ch.uuid) && ch.properties and notifies != 0) c.subscribe(ch)
            }
        }
        if (service.uuid in Uuids.zwiftServices) {
            // The KICKR CORE bridges the Zwift Ride shifters through its own Zwift
            // service: the same device can be power/trainer AND button source.
            // Don't let a bridge claim the Ride slot.
            if (addr != powerSlot && addr != hrSlot) rideSlot = addr
            log(mapOf("src" to "ble", "ev" to "zwiftChars", "name" to (deviceName(addr) ?: "?"),
                      "chars" to service.characteristics.map { "${it.uuid.short}:${it.properties}" }))
        }
        proxy.mirror(service, c)
    }

    /** Push a control target to the attached trainer. Returns the applied (clamped) mode. */
    fun setTrainerMode(mode: TrainerMode, rider: Rider): TrainerMode {
        val m = trainer.set(mode, rider)
        log(mapOf("src" to "ble", "ev" to "trainerSet", "mode" to m.label, "zwift" to trainer.speaksZwift,
                  "raw" to (if (trainer.speaksZwift) ZwiftHub.frames(m, rider) else null)?.map { it.hex() }.orEmpty()))
        // Downstream Orbeats won't hear this from the trainer either — we're
        // the writer. Notify them ourselves on the mirrored status char.
        proxy.push(Uuids.machineStatus, FtmsMachineStatus.encode(m, rider))
        return m
    }

    // MARK: Packet decode

    override fun onRead(c: Conn, ch: BluetoothGattCharacteristic, value: ByteArray?) = proxy.upstreamRead(c, ch, value)

    override fun onValue(c: Conn, ch: BluetoothGattCharacteristic, value: ByteArray) {
        proxy.upstreamRead(c, ch, value)
        val addr = c.device.address
        val device = deviceName(addr)
        when {
            Uuids.isButtonChar(ch.uuid) -> {
                log(mapOf("src" to "zwiftraw", "char" to ch.uuid.short,
                          "raw" to value.hex(), "device" to device))
                val frame = buttonDecode.handle(value) ?: return
                // Translate the proprietary bitmap into neutral intents for Core.
                val inputs = buildList {
                    if (frame.newlyPressed.any { it and ZwiftButtonFrame.SHIFT_UP != 0L }) add(HandlebarInput.ShiftUp)
                    if (frame.newlyPressed.any { it and ZwiftButtonFrame.SHIFT_DOWN != 0L }) add(HandlebarInput.ShiftDown)
                }
                if (inputs.isNotEmpty()) emit(SensorEvent.Handlebar(inputs))
                log(mapOf("src" to "ride", "raw" to frame.raw, "pressed" to frame.pressed, "device" to device))
            }
            // Only the HR-slot device: a bridge in the power slot could expose HR too.
            ch.uuid == Uuids.hrMeasurement -> if (addr == hrSlot) {
                HeartRateParser.parse(value, device)?.let { log(HeartRateParser.logFields(it)); emit(SensorEvent.HeartRate(it)) }
            }
            // Only the power-slot device: two sources would corrupt the rev counters.
            ch.uuid == Uuids.powerMeasurement -> if (addr == powerSlot) {
                powerParser.parse(value, device)?.let { log(it.logFields); emit(SensorEvent.Power(it.reading)) }
            }
            ch.uuid == Uuids.ftmsIndoorBikeData -> if (addr == powerSlot && addr !in cpsDevices) {
                FtmsIndoorBikeParser.parse(value, device)?.let { p ->
                    log(p.logFields)
                    p.reading?.let { emit(SensorEvent.Power(it)) }
                }
            }
            ch.uuid == Uuids.machineStatus -> if (addr == powerSlot) {
                log(mapOf("src" to "ble", "ev" to "ftmsStatus", "name" to (device ?: "?"), "raw" to value.hex()))
                FtmsMachineStatus.parse(value)?.let { trainer.observed(it); emit(SensorEvent.Mode(it)) }
            }
        }
    }
}

/**
 * Controls an FTMS trainer: ERG (0x05), resistance (0x04) and sim (0x11), or
 * the Zwift Protocol (`ZwiftHub`) when the trainer has it.
 *
 * ponytail: capability flags (0x2AD2 feature char) unread — writes are sent blindly.
 */
class Trainer {
    private var conn: Conn? = null
    private var control: BluetoothGattCharacteristic? = null
    private var zwiftConn: Conn? = null
    private var zwiftRx: BluetoothGattCharacteristic? = null
    /** Last applied (clamped) mode; null while detached or before the first target. */
    var mode: TrainerMode? = null; private set
    val speaksZwift: Boolean get() = zwiftRx != null && zwiftConn != null

    /** Take control and start. */
    fun attach(c: Conn, ch: BluetoothGattCharacteristic) {
        conn = c; control = ch
        // FTMS requires control-point indications enabled before it accepts commands.
        c.subscribe(ch)
        c.write(ch, byteArrayOf(0x00))   // request control
        c.write(ch, byteArrayOf(0x07))   // start/resume
    }

    /** Zwift Protocol channel on the same trainer (sync RX). Call after RideOn. */
    fun attachZwift(c: Conn, ch: BluetoothGattCharacteristic) {
        zwiftConn = c; zwiftRx = ch
        ZwiftHub.initFrames.forEach { c.write(ch, it) }
    }

    fun detach() { conn = null; control = null; mode = null; zwiftConn = null; zwiftRx = null }

    /** Trainer told us its target (possibly set by another app) — adopt it. */
    fun observed(m: TrainerMode) { mode = m }

    /** Push a control target. Without hardware this still clamps and records. */
    fun set(requested: TrainerMode, rider: Rider): TrainerMode {
        val m = requested.clamped
        val zc = zwiftConn; val zrx = zwiftRx
        val frames = if (zc != null && zrx != null) ZwiftHub.frames(m, rider) else null
        if (frames != null) {
            frames.forEach { zc!!.write(zrx!!, it) }
            mode = m
            return m
        }
        val c = conn ?: return m
        val ch = control ?: return m
        c.write(ch, when (m) {
            is TrainerMode.Erg -> i16Frame(0x05, m.targetWatts)            // sint16 LE, 1 W
            is TrainerMode.Resistance -> i16Frame(0x04, m.percent * 10)   // 0.1 % steps. ponytail: read 0x2AD6 instead
            is TrainerMode.Sim -> byteArrayOf(0x11) + m.simParams(rider)!!.bytes
        })
        mode = m
        return m
    }

    private fun i16Frame(op: Int, v: Int) = byteArrayOf(op.toByte(), (v and 0xFF).toByte(), ((v shr 8) and 0xFF).toByte())
}
