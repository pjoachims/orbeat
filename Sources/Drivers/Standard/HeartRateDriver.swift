import CoreBluetooth

final class HeartRateDriver: EquipmentDriver {
    static let hrService = CBUUID(string: "180D")
    static let hrMeasurement = CBUUID(string: "2A37")

    private let logSink: (any LogWriting)?
    private let deviceName: (CBPeripheral) -> String?

    init(log: (any LogWriting)? = nil, deviceName: @escaping (CBPeripheral) -> String?) {
        self.logSink = log
        self.deviceName = deviceName
    }

    var scannedServices: [CBUUID] { [Self.hrService] }

    func matches(_ name: String?, advertisedServices: [CBUUID]) -> Bool {
        advertisedServices.contains(Self.hrService)
    }

    func characteristicDiscovered(_ peripheral: CBPeripheral,
                                  _ characteristic: CBCharacteristic) -> [SensorEvent] {
        guard characteristic.uuid == Self.hrMeasurement else { return [] }
        peripheral.setNotifyValue(true, for: characteristic)
        return [.heartLinkUp(device: peripheral.name ?? "BLE device")]
    }

    func handle(_ peripheral: CBPeripheral,
                _ characteristic: CBCharacteristic,
                _ bytes: [UInt8]) -> [SensorEvent] {
        guard characteristic.uuid == Self.hrMeasurement else { return [] }
        guard let reading = HeartRateParser.parse(bytes, device: deviceName(peripheral)) else { return [] }
        logSink?.log(HeartRateParser.logFields(reading))
        return [.heartRate(reading)]
    }
}
