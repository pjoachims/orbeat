import CoreBluetooth

/// One equipment family's protocol knowledge. The hub routes bytes;
/// drivers decode them and speak only SensorEvent + Core types.
/// Minimal by design: only what today's three families need. Do NOT
/// speculate about future devices.
protocol EquipmentDriver: AnyObject {
    /// Services this family answers to (included in scans/discovery).
    var scannedServices: [CBUUID] { get }
    /// Advertisement-level match (name heuristics allowed, e.g. "zwift").
    func matches(_ name: String?, advertisedServices: [CBUUID]) -> Bool
    /// Called once per discovered characteristic: subscribe, handshakes,
    /// control-point claims. May return immediate events.
    func characteristicDiscovered(_ peripheral: CBPeripheral,
                                  _ characteristic: CBCharacteristic) -> [SensorEvent]
    /// Decode one notification. Empty array = ignore packet.
    func handle(_ peripheral: CBPeripheral,
                _ characteristic: CBCharacteristic,
                _ bytes: [UInt8]) -> [SensorEvent]
}
