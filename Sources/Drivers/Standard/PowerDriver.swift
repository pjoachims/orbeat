import CoreBluetooth
import Foundation

final class PowerDriver: EquipmentDriver {
    static let powerService = CBUUID(string: "1818")
    static let powerMeasurement = CBUUID(string: "2A63")
    /// FTMS Indoor Bike Data — fallback telemetry source for trainers without
    /// a Cycling Power Service.
    static let ftmsIndoorBikeData = CBUUID(string: "2AD2")

    private let logSink: (any LogWriting)?
    private let deviceName: (CBPeripheral) -> String?
    private let powerParser = CyclingPowerParser()
    /// Peripherals whose power data arrives via the Cycling Power Service;
    /// their FTMS stream is ignored (no rev counters, redundant watts).
    private var cpsDevices = Set<UUID>()

    init(log: (any LogWriting)? = nil, deviceName: @escaping (CBPeripheral) -> String?) {
        self.logSink = log
        self.deviceName = deviceName
    }

    var scannedServices: [CBUUID] { [Self.powerService] }

    func matches(_ name: String?, advertisedServices: [CBUUID]) -> Bool {
        advertisedServices.contains(Self.powerService) && !advertisedServices.contains(HeartRateDriver.hrService)
    }

    func characteristicDiscovered(_ peripheral: CBPeripheral,
                                  _ characteristic: CBCharacteristic) -> [SensorEvent] {
        if characteristic.uuid == Self.powerMeasurement {
            peripheral.setNotifyValue(true, for: characteristic)
            cpsDevices.insert(peripheral.identifier)
            return [.powerLinkUp(device: peripheral.name ?? "Power meter")]
        }
        if characteristic.uuid == Self.ftmsIndoorBikeData {
            // CPS devices: their FTMS stream is ignored in handle(), so don't
            // subscribe — through a bridge it only competes with 2A63 for the
            // phone's notify queue.
            if characteristic.properties.contains(.notify), !cpsDevices.contains(peripheral.identifier) {
                peripheral.setNotifyValue(true, for: characteristic)
                return [.powerLinkUp(device: peripheral.name ?? "Trainer")]
            }
        }
        return []
    }

    func handle(_ peripheral: CBPeripheral,
                _ characteristic: CBCharacteristic,
                _ bytes: [UInt8]) -> [SensorEvent] {
        switch characteristic.uuid {
        case Self.powerMeasurement:
            guard let packet = powerParser.parse(bytes, device: deviceName(peripheral)) else { return [] }
            logSink?.log(packet.logFields)
            return [.power(packet.reading)]
        case Self.ftmsIndoorBikeData:
            guard !cpsDevices.contains(peripheral.identifier) else { return [] }
            guard let packet = FtmsIndoorBikeParser.parse(bytes, device: deviceName(peripheral)) else { return [] }
            logSink?.log(packet.logFields)
            if let reading = packet.reading { return [.power(reading)] }
            return []
        default:
            return []
        }
    }

    func reset(for peripheral: CBPeripheral) {
        cpsDevices.remove(peripheral.identifier)
        powerParser.reset()
    }
}
