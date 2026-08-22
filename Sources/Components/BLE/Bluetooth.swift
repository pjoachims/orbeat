import Foundation
import CoreBluetooth

/// Connects standard BLE sensors:
/// - Heart Rate (service 0x180D, char 0x2A37) — Polar, Wahoo, Garmin broadcast,
///   CooSpo, most chest straps & many watches. NOT Fitbit: proprietary link.
/// - Cycling Power (service 0x1818, char 0x2A63) — Wahoo KICKR, power meters.
/// - FTMS trainers (control point 0x2AD9) and Zwift Ride/Play button frames.
///
/// Self-contained component: it knows nothing about the UI model or app
/// policies. It logs every raw packet through the injected `LogWriting` sink
/// and reports decoded results upward as `BLEEvent`s via `onEvent`.
final class BLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    /// Decoded events for the app layer (set before scanning starts).
    var onEvent: ((BLEEvent) -> Void)?

    private let hrService = CBUUID(string: "180D")
    private let hrMeasurement = CBUUID(string: "2A37")
    private let powerService = CBUUID(string: "1818")
    private let powerMeasurement = CBUUID(string: "2A63")
    /// FTMS Indoor Bike Data — fallback telemetry source for trainers without
    /// a Cycling Power Service.
    private let ftmsIndoorBikeData = CBUUID(string: "2AD2")

    struct Device {
        let peripheral: CBPeripheral
        let isPower: Bool
        /// A Zwift Play/Ride handlebar controller — an input device, not a sensor.
        var isRide: Bool = false
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
    private var ridePeripheral: CBPeripheral?
    private let logSink: (any LogWriting)?
    /// Everything seen while scanning, for the "Connect Equipment" menu.
    private(set) var discovered: [Device] = []
    /// Devices the user has connected before — only these auto-connect.
    private var known: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "knownDevices") ?? [])

    // Packet decoding (same component): pure parsers keep rev-delta state.
    private let ride = ZwiftRideController()
    private let trainer = Trainer()
    private let powerParser = CyclingPowerParser()
    /// Peripherals whose power data arrives via the Cycling Power Service;
    /// their FTMS stream is ignored (no rev counters, redundant watts).
    private var cpsDevices = Set<UUID>()

    private func emit(_ event: BLEEvent) { onEvent?(event) }
    private func log(_ fields: [String: Any]) { logSink?.log(fields) }

    /// Best-known name for a peripheral — advertisement name as fallback,
    /// mirroring Device.name (some devices never set peripheral.name).
    private func deviceName(_ p: CBPeripheral) -> String? {
        p.name ?? discovered.first { $0.peripheral.identifier == p.identifier }?.advName
    }

    func isConnected(_ d: Device) -> Bool { d.peripheral.state == .connected }
    func isKnown(_ d: Device) -> Bool { known.contains(d.peripheral.identifier.uuidString) }

    /// Drop from auto-connect and disconnect if currently connected.
    func forget(_ d: Device) {
        known.remove(d.peripheral.identifier.uuidString)
        UserDefaults.standard.set(Array(known), forKey: "knownDevices")
        if d.peripheral === hrPeripheral || d.peripheral === powerPeripheral
            || d.peripheral === ridePeripheral {
            central.cancelPeripheralConnection(d.peripheral)   // cleanup runs in didDisconnect
        }
    }

    /// Connect a specific device, replacing the current one of the same type.
    func connect(_ d: Device) {
        if d.isRide {
            if let p = ridePeripheral, p !== d.peripheral { central.cancelPeripheralConnection(p) }
            ridePeripheral = d.peripheral
        } else if d.isPower {
            if let p = powerPeripheral, p !== d.peripheral { central.cancelPeripheralConnection(p) }
            powerPeripheral = d.peripheral
        } else {
            if let p = hrPeripheral, p !== d.peripheral { central.cancelPeripheralConnection(p) }
            hrPeripheral = d.peripheral
        }
        d.peripheral.delegate = self
        emit(.status("Connecting \(d.name)…"))
        central.connect(d.peripheral)
        known.insert(d.peripheral.identifier.uuidString)
        UserDefaults.standard.set(Array(known), forKey: "knownDevices")
    }

    init(log: (any LogWriting)? = nil) {
        self.logSink = log
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
        central.scanForPeripherals(
            withServices: scanningAll ? nil : [hrService, powerService, ZwiftRideController.service])
    }

    // MARK: Central lifecycle

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            emit(.status("Scanning…"))
            scan()
        case .unauthorized:
            emit(.status("Bluetooth not authorized"))
        case .poweredOff:
            emit(.status("Bluetooth off"))
        default:
            emit(.status("Bluetooth unavailable"))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        // Zwift Ride/Play advertise the service UUID only in the scan response, so
        // advertisementData often omits it — fall back to the name.
        let nameHit = (peripheral.name ?? advName ?? "").localizedCaseInsensitiveContains("zwift")
        let isRide = advertised.contains(ZwiftRideController.service) || nameHit
        let isPower = advertised.contains(powerService) && !advertised.contains(hrService)
        // Filtered scans imply a sensor even when the callback omits the service list.
        let isSensor = !scanningAll || advertised.contains(hrService)
            || advertised.contains(powerService) || isRide
        if !isSensor && peripheral.name == nil && advName == nil { return }   // skip anonymous junk in search-all
        if !discovered.contains(where: { $0.peripheral.identifier == peripheral.identifier }) {
            discovered.append(Device(peripheral: peripheral, isPower: isPower, isRide: isRide,
                                     isSensor: isSensor, advName: advName))
        }
        // Auto-connect only devices the user has connected before; new ones
        // wait in the "Connect Equipment" menu.
        let slotFree = isRide ? ridePeripheral == nil
                     : isPower ? powerPeripheral == nil : hrPeripheral == nil
        guard isSensor, slotFree else { return }
        if known.contains(peripheral.identifier.uuidString) {
            connect(Device(peripheral: peripheral, isPower: isPower, isRide: isRide))
        } else {
            emit(.status("Found \(peripheral.name ?? "device") — right-click → Connect Equipment"))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log(["src": "ble", "ev": "connected", "name": peripheral.name ?? "?",
             "ride": peripheral === ridePeripheral])
        peripheral.discoverServices([hrService, powerService, Trainer.service, ZwiftRideController.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        log(["src": "ble", "ev": "failToConnect", "name": peripheral.name ?? "?",
             "err": error?.localizedDescription ?? ""])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if peripheral === hrPeripheral {
            hrPeripheral = nil
            emit(.heartLinkDown)
            emit(.status("Disconnected · rescanning…"))
        }
        if peripheral === powerPeripheral {
            powerPeripheral = nil
            cpsDevices.remove(peripheral.identifier)
            powerParser.reset()
            trainer.detach()
            emit(.trainerLost)
            emit(.powerLinkDown)
        }
        if peripheral === ridePeripheral {
            ridePeripheral = nil
            ride.reset()
        }
        log(["src": "ble", "ev": "disconnected", "name": peripheral.name ?? "?",
             "err": error?.localizedDescription ?? ""])
        scan()
    }

    // MARK: Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        log(["src": "ble", "ev": "services", "name": peripheral.name ?? "?",
             "uuids": (peripheral.services ?? []).map { $0.uuid.uuidString },
             "err": error?.localizedDescription ?? ""])
        peripheral.services?.forEach { svc in
            if svc.uuid == hrService {
                peripheral.discoverCharacteristics([hrMeasurement], for: svc)
            }
            if svc.uuid == powerService {
                peripheral.discoverCharacteristics([powerMeasurement], for: svc)
            }
            if svc.uuid == Trainer.service {
                peripheral.discoverCharacteristics([Trainer.controlPoint, ftmsIndoorBikeData], for: svc)
            }
            if svc.uuid == ZwiftRideController.service {
                peripheral.discoverCharacteristics(nil, for: svc)   // discover all, incl. 0006
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        service.characteristics?.forEach { ch in
            if ch.uuid == hrMeasurement {
                peripheral.setNotifyValue(true, for: ch)
                emit(.heartLinkUp(device: peripheral.name ?? "BLE device"))
            }
            if ch.uuid == powerMeasurement {
                peripheral.setNotifyValue(true, for: ch)
                cpsDevices.insert(peripheral.identifier)
                emit(.powerLinkUp(device: peripheral.name ?? "Power meter"))
            }
            if ch.uuid == ftmsIndoorBikeData {
                if ch.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: ch)
                    if !cpsDevices.contains(peripheral.identifier) {
                        emit(.powerLinkUp(device: peripheral.name ?? "Trainer"))
                    }
                }
            }
            if ch.uuid == Trainer.controlPoint {
                trainer.attach(peripheral, control: ch)
                emit(.trainerReady)
            }
            if ZwiftRideController.isButtonChar(ch.uuid) {
                if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: ch)     // button notifications
                }
            }
            if ch.uuid == ZwiftRideController.syncRx {
                // "RideOn" handshake starts the button stream. Plaintext — no key
                // exchange needed for this controller family (qdomyos-zwift).
                let type: CBCharacteristicWriteType =
                    ch.properties.contains(.write) ? .withResponse : .withoutResponse
                peripheral.writeValue(ZwiftRideController.handshake, for: ch, type: type)
            }
        }
        if service.uuid == ZwiftRideController.service {
            // Adopt as the Ride controller. The KICKR CORE bridges the Zwift Ride
            // shifters through its own Zwift service, so the SAME peripheral can be
            // both the power/trainer device and the button source — don't clear
            // the power/hr slots here.
            ridePeripheral = peripheral
            let chars = (service.characteristics ?? []).map {
                "\($0.uuid.uuidString.suffix(4)):\($0.properties.rawValue)" }
            log(["src": "ble", "ev": "zwiftChars", "name": peripheral.name ?? "?",
                 "chars": chars])   // props rawValue: notify=0x10, write=0x08, wwr=0x04
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.service?.uuid == ZwiftRideController.service else { return }
        log(["src": "ble", "ev": "notifyState",
             "char": characteristic.uuid.uuidString.suffix(4).description,
             "on": characteristic.isNotifying, "err": error?.localizedDescription ?? ""])
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        log(["src": "ble", "ev": "wrote",
             "char": characteristic.uuid.uuidString.suffix(4).description,
             "err": error?.localizedDescription ?? ""])
    }

    /// Push a control target to the attached trainer. Returns the applied
    /// (clamped) mode so the caller can keep its state in sync.
    @discardableResult
    func setTrainerMode(_ mode: TrainerMode) -> TrainerMode {
        trainer.set(mode)
    }

    // MARK: Packet decode

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        switch characteristic.uuid {
        case _ where ZwiftRideController.isButtonChar(characteristic.uuid):
            // Accept button frames from any peripheral exposing the Zwift service
            // (both a standalone Zwift Ride and the KICKR bridge can appear).
            // Raw log every notification so we can see the actual frame format.
            log(["src": "zwiftraw", "char": characteristic.uuid.uuidString.suffix(4).description,
                 "raw": bytes.map { String(format: "%02x", $0) }.joined()])
            guard let frame = ride.handle(bytes) else { return }
            // Translate the proprietary bitmap into neutral intents for Core.
            var inputs: [HandlebarInput] = []
            if frame.newlyPressed.contains(where: { $0 & ZwiftButtonFrame.shiftUp != 0 }) {
                inputs.append(.shiftUp)
            }
            if frame.newlyPressed.contains(where: { $0 & ZwiftButtonFrame.shiftDown != 0 }) {
                inputs.append(.shiftDown)
            }
            if !inputs.isEmpty { emit(.handlebar(inputs)) }
            log(["src": "ride", "raw": frame.raw, "pressed": frame.pressed])
        case hrMeasurement:
            // Only the HR-slot device; a rebroadcast bridge in the power slot
            // could expose HR too and double-feed the model.
            guard peripheral === hrPeripheral else { return }
            rebroadcaster.relay(data, isPower: false)
            guard let reading = HeartRateParser.parse(bytes, device: deviceName(peripheral)) else { return }
            log(HeartRateParser.logFields(reading))
            emit(.heartRate(reading))
        case powerMeasurement:
            // Only the power-slot device; two sources interleaving here would
            // corrupt the parser's cumulative rev counters → speed/cadence spikes.
            guard peripheral === powerPeripheral else { return }
            rebroadcaster.relay(data, isPower: true)
            guard let packet = powerParser.parse(bytes, device: deviceName(peripheral)) else { return }
            log(packet.logFields)
            emit(.power(packet.reading))
        case ftmsIndoorBikeData:
            guard peripheral === powerPeripheral else { return }
            guard !cpsDevices.contains(peripheral.identifier) else { return }
            guard let packet = FtmsIndoorBikeParser.parse(bytes, device: deviceName(peripheral)) else { return }
            log(packet.logFields)
            if let reading = packet.reading { emit(.power(reading)) }
        default:
            break
        }
    }
}
