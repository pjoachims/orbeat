import Foundation
import CoreBluetooth

/// Connects standard BLE sensors:
/// - Heart Rate (service 0x180D, char 0x2A37) — Polar, Wahoo, Garmin broadcast,
///   CooSpo, most chest straps & many watches. NOT Fitbit: proprietary link.
/// - Cycling Power (service 0x1818, char 0x2A63) — Wahoo KICKR, power meters.
final class BLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let hrService = CBUUID(string: "180D")
    private let hrMeasurement = CBUUID(string: "2A37")
    private let powerService = CBUUID(string: "1818")
    private let powerMeasurement = CBUUID(string: "2A63")

    struct Device {
        let peripheral: CBPeripheral
        let isPower: Bool
        /// Advertised a standard HR/power service. False only for devices found
        /// by the unfiltered "search all" scan.
        var isSensor: Bool = true
        /// Name from the advertisement packet — some devices never set peripheral.name.
        var advName: String? = nil
        var name: String { peripheral.name ?? advName ?? "Unknown device" }
    }

    /// Optional bridge mode: relay received packets out as a BLE peripheral.
    let rebroadcaster = Rebroadcaster()

    private var central: CBCentralManager!
    private var hrPeripheral: CBPeripheral?
    private var powerPeripheral: CBPeripheral?
    private weak var model: HeartRate?
    /// Everything seen while scanning, for the "Connect Equipment" menu.
    private(set) var discovered: [Device] = []
    /// Devices the user has connected before — only these auto-connect.
    private var known: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "knownDevices") ?? [])

    // Previous cumulative rev counters, for cadence/speed deltas.
    private var lastCrank: (revs: UInt16, time: UInt16)?
    private var lastWheel: (revs: UInt32, time: UInt16)?
    // ponytail: fixed 700x25c circumference (2.105 m); make it a setting if speed reads off
    private let wheelCircumference = 2.105

    func isConnected(_ d: Device) -> Bool { d.peripheral.state == .connected }
    func isKnown(_ d: Device) -> Bool { known.contains(d.peripheral.identifier.uuidString) }

    /// Drop from auto-connect and disconnect if currently connected.
    func forget(_ d: Device) {
        known.remove(d.peripheral.identifier.uuidString)
        UserDefaults.standard.set(Array(known), forKey: "knownDevices")
        if d.peripheral === hrPeripheral || d.peripheral === powerPeripheral {
            central.cancelPeripheralConnection(d.peripheral)   // cleanup runs in didDisconnect
        }
    }

    /// Connect a specific device, replacing the current one of the same type.
    func connect(_ d: Device) {
        if d.isPower {
            if let p = powerPeripheral, p !== d.peripheral { central.cancelPeripheralConnection(p) }
            powerPeripheral = d.peripheral
        } else {
            if let p = hrPeripheral, p !== d.peripheral { central.cancelPeripheralConnection(p) }
            hrPeripheral = d.peripheral
        }
        d.peripheral.delegate = self
        model?.bleStatus = "Connecting \(d.name)…"
        central.connect(d.peripheral)
        known.insert(d.peripheral.identifier.uuidString)
        UserDefaults.standard.set(Array(known), forKey: "knownDevices")
    }

    init(model: HeartRate) {
        self.model = model
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    /// Unfiltered scan: list every nearby BLE device, not just HR/power advertisers.
    private(set) var scanningAll = false
    func setScanAll(_ all: Bool) {
        guard all != scanningAll else { return }
        scanningAll = all
        guard central.state == .poweredOn else { return }
        central.stopScan()
        scan()
    }

    // ponytail: scans forever so the equipment menu stays fresh; stop-when-connected if battery matters
    private func scan() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: scanningAll ? nil : [hrService, powerService])
    }

    // MARK: Central lifecycle

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            model?.bleStatus = "Scanning…"
            scan()
        case .unauthorized:
            model?.bleStatus = "Bluetooth not authorized"
        case .poweredOff:
            model?.bleStatus = "Bluetooth off"
        default:
            model?.bleStatus = "Bluetooth unavailable"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let isPower = advertised.contains(powerService) && !advertised.contains(hrService)
        // Filtered scans imply a sensor even when the callback omits the service list.
        let isSensor = !scanningAll || advertised.contains(hrService) || advertised.contains(powerService)
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        if !isSensor && peripheral.name == nil && advName == nil { return }   // skip anonymous junk in search-all
        if !discovered.contains(where: { $0.peripheral.identifier == peripheral.identifier }) {
            discovered.append(Device(peripheral: peripheral, isPower: isPower,
                                     isSensor: isSensor, advName: advName))
        }
        // Auto-connect only devices the user has connected before; new ones
        // wait in the "Connect Equipment" menu.
        let slotFree = isPower ? powerPeripheral == nil : hrPeripheral == nil
        guard isSensor, slotFree else { return }
        if known.contains(peripheral.identifier.uuidString) {
            connect(Device(peripheral: peripheral, isPower: isPower))
        } else {
            model?.bleStatus = "Found \(peripheral.name ?? "device") — right-click → Connect Equipment"
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([hrService, powerService])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if peripheral === hrPeripheral {
            hrPeripheral = nil
            model?.setLive(false, source: "Disconnected")
            model?.bleStatus = "Disconnected · rescanning…"
        }
        if peripheral === powerPeripheral {
            powerPeripheral = nil
            model?.watts = nil
            model?.cadence = nil
            model?.speedKmh = nil
            model?.powerSource = ""
            lastCrank = nil
            lastWheel = nil
        }
        scan()
    }

    // MARK: Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        peripheral.services?.forEach { svc in
            if svc.uuid == hrService {
                peripheral.discoverCharacteristics([hrMeasurement], for: svc)
            }
            if svc.uuid == powerService {
                peripheral.discoverCharacteristics([powerMeasurement], for: svc)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        service.characteristics?.forEach { ch in
            if ch.uuid == hrMeasurement {
                peripheral.setNotifyValue(true, for: ch)
                model?.setLive(true, source: peripheral.name ?? "BLE device")
            }
            if ch.uuid == powerMeasurement {
                peripheral.setNotifyValue(true, for: ch)
                model?.powerSource = peripheral.name ?? "Power meter"
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        switch characteristic.uuid {
        case hrMeasurement:
            rebroadcaster.relay(data, isPower: false)
            // Spec: byte0 flags; bit0 = value format (0 = UInt8, 1 = UInt16 LE).
            let bpm: Int
            if (bytes.count >= 2) && (bytes[0] & 0x01) == 0 {
                bpm = Int(bytes[1])
            } else if bytes.count >= 3 {
                bpm = Int(bytes[1]) | (Int(bytes[2]) << 8)
            } else { return }
            if bpm > 0 { model?.ingest(bpm) }
        case powerMeasurement:
            rebroadcaster.relay(data, isPower: true)
            // Spec: flags UInt16 LE, instantaneous power SInt16 LE, then optional
            // fields in flag-bit order. We care about wheel revs (bit4, speed)
            // and crank revs (bit5, cadence).
            guard bytes.count >= 4 else { return }
            let flags = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
            model?.watts = Int(Int16(bitPattern: UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)))
            model?.touch()   // power packets count as a sync too
            var i = 4
            if flags & 0x0001 != 0 { i += 1 }   // pedal power balance
            if flags & 0x0004 != 0 { i += 2 }   // accumulated torque
            if flags & 0x0010 != 0, bytes.count >= i + 6 {   // wheel revolution data
                let revs = UInt32(bytes[i]) | (UInt32(bytes[i+1]) << 8)
                         | (UInt32(bytes[i+2]) << 16) | (UInt32(bytes[i+3]) << 24)
                let t = UInt16(bytes[i+4]) | (UInt16(bytes[i+5]) << 8)   // 1/2048 s
                if let last = lastWheel {
                    if t == last.time {
                        model?.speedKmh = 0   // wheel stopped: no new event
                    } else {
                        let dt = Double(t &- last.time) / 2048.0
                        model?.speedKmh = Double(revs &- last.revs) * wheelCircumference / dt * 3.6
                    }
                }
                lastWheel = (revs, t)
                i += 6
            }
            if flags & 0x0020 != 0, bytes.count >= i + 4 {   // crank revolution data
                let revs = UInt16(bytes[i]) | (UInt16(bytes[i+1]) << 8)
                let t = UInt16(bytes[i+2]) | (UInt16(bytes[i+3]) << 8)   // 1/1024 s
                if let last = lastCrank {
                    if t == last.time {
                        model?.cadence = 0   // coasting: no new crank event
                    } else {
                        let dt = Double(t &- last.time) / 1024.0
                        model?.cadence = Int((Double(revs &- last.revs) / dt * 60).rounded())
                    }
                }
                lastCrank = (revs, t)
            }
        default:
            break
        }
    }
}
