package com.vibecode.orbeat.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.UUID

/** 16-bit SIG UUID → full UUID. */
fun uuid16(short: String): UUID = UUID.fromString("0000$short-0000-1000-8000-00805F9B34FB")
val CCCD: UUID = uuid16("2902")
val UUID.short: String get() = toString().substring(4, 8).uppercase()

fun BluetoothGattCharacteristic.has(prop: Int) = properties and prop != 0

/**
 * One GATT client connection. Android's GATT allows one outstanding
 * operation per connection, so writes, subscribes and reads go through a
 * serial queue; every callback is hopped to the main thread, where all of
 * Orbeat's BLE state lives (CoreBluetooth's `queue: .main`).
 *
 * ponytail: no per-op timeout — a lost ack stalls the queue until the link drops (which closes it).
 */
@SuppressLint("MissingPermission")
class Conn(ctx: Context, val device: BluetoothDevice, private val listener: Listener) : BluetoothGattCallback() {
    interface Listener {
        fun onConnected(c: Conn) {}
        /** `wasConnected` false = the connect itself failed (e.g. status 133). */
        fun onDisconnected(c: Conn, wasConnected: Boolean) {}
        fun onServices(c: Conn) {}
        fun onValue(c: Conn, ch: BluetoothGattCharacteristic, value: ByteArray) {}
        fun onRead(c: Conn, ch: BluetoothGattCharacteristic, value: ByteArray?) {}
    }

    private val main = Handler(Looper.getMainLooper())
    private val ops = ArrayDeque<() -> Boolean>()
    private var busy = false
    var connected = false; private set
    var closed = false; private set
    val gatt: BluetoothGatt = device.connectGatt(ctx, false, this, BluetoothDevice.TRANSPORT_LE)
    val idle: Boolean get() = !busy && ops.isEmpty()

    fun close() {
        if (closed) return
        closed = true
        ops.clear()
        gatt.disconnect()
        gatt.close()
    }

    fun discover() = enqueue { gatt.discoverServices() }

    /** Queue an operation; `op` starts it and returns false if it didn't (skipped). */
    fun enqueue(op: () -> Boolean) { ops.addLast(op); next() }

    /** With response whenever the characteristic supports it. */
    fun write(ch: BluetoothGattCharacteristic, data: ByteArray,
              withResponse: Boolean = ch.has(BluetoothGattCharacteristic.PROPERTY_WRITE)) = enqueue {
        val type = if (withResponse) BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                   else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        gatt.writeCharacteristic(ch, data, type) == BluetoothGatt.GATT_SUCCESS
    }

    /** Notifications, or indications when that's all the characteristic offers. */
    fun subscribe(ch: BluetoothGattCharacteristic) = enqueue {
        val d = ch.getDescriptor(CCCD) ?: return@enqueue false
        val v = if (ch.has(BluetoothGattCharacteristic.PROPERTY_NOTIFY)) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                else BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        gatt.setCharacteristicNotification(ch, true) &&
            gatt.writeDescriptor(d, v) == BluetoothGatt.GATT_SUCCESS
    }

    fun read(ch: BluetoothGattCharacteristic) = enqueue { gatt.readCharacteristic(ch) }

    fun requestMtu(mtu: Int) = enqueue { gatt.requestMtu(mtu) }

    private fun next() {
        while (!busy && !closed) {
            val op = ops.removeFirstOrNull() ?: return
            busy = op()
        }
    }

    private fun done() { busy = false; next() }

    private fun ui(f: () -> Unit) { main.post { if (!closed) f() } }

    override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) = ui {
        if (newState == BluetoothProfile.STATE_CONNECTED) {
            connected = true
            listener.onConnected(this)
        } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
            val was = connected
            connected = false
            close()
            listener.onDisconnected(this, was)
        }
    }

    override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = ui { listener.onServices(this); done() }

    /** Peer's GATT table changed (its app restarted): rediscover. */
    override fun onServiceChanged(g: BluetoothGatt) = ui { ops.clear(); busy = false; discover() }

    override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray) =
        ui { listener.onValue(this, ch, value) }

    override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray, status: Int) = ui {
        listener.onRead(this, ch, if (status == BluetoothGatt.GATT_SUCCESS) value else null)
        done()
    }

    override fun onCharacteristicWrite(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) = ui { done() }
    override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) = ui { done() }
    override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) = ui { done() }
}
