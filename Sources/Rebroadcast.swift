import Foundation
import CoreBluetooth

/// Re-advertises received sensor data as a standard BLE peripheral ("Orbeat"),
/// so other devices (Zwift on Apple TV, another Mac, a bike computer) can pair
/// with this app as if it were the strap/power meter itself. Sensor packets
/// are relayed byte-for-byte — no re-encoding, full fidelity.
final class Rebroadcaster: NSObject, CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager?
    private let hrChar = CBMutableCharacteristic(
        type: CBUUID(string: "2A37"), properties: [.notify], value: nil, permissions: [.readable])
    private let powerChar = CBMutableCharacteristic(
        type: CBUUID(string: "2A63"), properties: [.notify], value: nil, permissions: [.readable])

    var enabled = UserDefaults.standard.bool(forKey: "rebroadcast") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "rebroadcast")
            enabled ? start() : stop()
        }
    }

    override init() {
        super.init()
        if enabled { start() }
    }

    private func start() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    private func stop() {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager = nil
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        let hr = CBMutableService(type: CBUUID(string: "180D"), primary: true)
        hr.characteristics = [hrChar]
        let power = CBMutableService(type: CBUUID(string: "1818"), primary: true)
        // Mandatory CP chars some apps read before pairing: feature (wheel+crank
        // rev flags — actual presence is per-packet) and sensor location (other).
        power.characteristics = [
            powerChar,
            CBMutableCharacteristic(type: CBUUID(string: "2A65"), properties: [.read],
                                    value: Data([0x0C, 0, 0, 0]), permissions: [.readable]),
            CBMutableCharacteristic(type: CBUUID(string: "2A5D"), properties: [.read],
                                    value: Data([0]), permissions: [.readable]),
        ]
        peripheral.add(hr)
        peripheral.add(power)
        peripheral.startAdvertising([
            CBAdvertisementDataLocalNameKey: "Orbeat",
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: "180D"), CBUUID(string: "1818")],
        ])
    }

    /// Forward a raw measurement packet exactly as received from the sensor.
    // ponytail: packet dropped if the notify queue is full — next reading is ≤1 s away
    func relay(_ data: Data, isPower: Bool) {
        guard let manager, manager.state == .poweredOn else { return }
        manager.updateValue(data, for: isPower ? powerChar : hrChar, onSubscribedCentrals: nil)
    }
}
