import Foundation
import CoreBluetooth

/// Orbeat ↔ Orbeat link over one custom GATT service. The Mac hosts it; the
/// iPhone connects as central, because a central link survives iOS
/// backgrounding while peripheral advertising gets throttled and anonymised.
/// Messages are `PeerWire` frames: server → client by notification,
/// client → server by write.
///
/// ponytail: no pairing/auth — first Orbeat Mac in range wins. Add an iCloud
/// shared token if a second household Mac ever shows up.
enum PeerUUID {
    static let service = CBUUID(string: "6F726265-0001-4F52-4245-41542D4C4E4B")
    static let toClient = CBUUID(string: "6F726265-0002-4F52-4245-41542D4C4E4B")
    static let toServer = CBUUID(string: "6F726265-0003-4F52-4245-41542D4C4E4B")
}

#if os(macOS)
typealias PeerLink = PeerServer
#else
typealias PeerLink = PeerClient
#endif

/// Mac side: publishes the service on the GattProxy's peripheral manager.
final class PeerServer {
    static let peerLabel = "iPhone"
    var onMessage: ((PeerMessage) -> Void)?
    var onConnected: ((Bool) -> Void)?
    private(set) var connected = false

    private let proxy: GattProxy
    private let tx = CBMutableCharacteristic(type: PeerUUID.toClient, properties: [.notify, .read],
                                             value: nil, permissions: [.readable])
    private let rx = CBMutableCharacteristic(type: PeerUUID.toServer,
                                             properties: [.write, .writeWithoutResponse],
                                             value: nil, permissions: [.writeable])
    /// Waiting for transmit-queue space. Commands in order; states coalesce.
    private var outbox: [PeerMessage] = []

    init(proxy: GattProxy) {
        self.proxy = proxy
        let svc = CBMutableService(type: PeerUUID.service, primary: true)
        svc.characteristics = [tx, rx]
        proxy.onHostedWrite = { [weak self] req in
            guard req.characteristic.uuid == PeerUUID.toServer, let v = req.value,
                  let m = PeerWire.decode(v) else { return }
            self?.onMessage?(m)
        }
        proxy.onHostedSubscribers = { [weak self] n in
            guard let self else { return }
            connected = n > 0
            if !connected { outbox.removeAll() }
            onConnected?(connected)
        }
        proxy.onReady = { [weak self] in self?.flush() }
        proxy.host(svc)
    }

    func send(_ m: PeerMessage) {
        guard connected else { return }
        if case .state = m, case .state = outbox.last { outbox.removeLast() }
        outbox.append(m)
        flush()
    }

    private func flush() {
        while let m = outbox.first, proxy.update(PeerWire.encode(m), for: tx) { outbox.removeFirst() }
    }
}

/// iPhone side: finds the Mac by service UUID, stays connected, reconnects
/// forever (a pending CoreBluetooth connect never times out).
final class PeerClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let peerLabel = "Mac"
    var onMessage: ((PeerMessage) -> Void)?
    var onConnected: ((Bool) -> Void)?
    var onLog: (([String: Any]) -> Void)?
    private(set) var connected = false {
        didSet { if connected != oldValue { onConnected?(connected) } }
    }

    private var central: CBCentralManager!
    private var peer: CBPeripheral?
    private var rx: CBCharacteristic?
    private static let savedKey = "peerMac"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func send(_ m: PeerMessage) {
        guard let peer, let rx, peer.state == .connected else { return }
        let data = PeerWire.encode(m)
        // Commands must arrive; state is resent every second anyway.
        if case .command = m {
            peer.writeValue(data, for: rx, type: .withResponse)
        } else if peer.canSendWriteWithoutResponse {
            peer.writeValue(data, for: rx, type: .withoutResponse)
        }
    }

    private func connect(_ p: CBPeripheral) {
        if let old = peer, old.identifier != p.identifier { central.cancelPeripheralConnection(old) }
        peer = p
        p.delegate = self
        central.connect(p)
    }

    private func search() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [PeerUUID.service])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onLog?(["src": "peer", "ev": "state", "state": central.state.rawValue])
        guard central.state == .poweredOn else { connected = false; rx = nil; return }
        if let id = UserDefaults.standard.string(forKey: Self.savedKey).flatMap(UUID.init),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
        }
        search()   // identifiers can rotate; the scan finds the Mac either way
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !connected, peripheral.state == .disconnected else { return }
        onLog?(["src": "peer", "ev": "found", "name": peripheral.name ?? "?"])
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onLog?(["src": "peer", "ev": "connected", "name": peripheral.name ?? "?"])
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedKey)
        central.stopScan()
        peripheral.discoverServices([PeerUUID.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        onLog?(["src": "peer", "ev": "failToConnect", "err": error?.localizedDescription ?? ""])
        lost(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        onLog?(["src": "peer", "ev": "disconnected", "err": error?.localizedDescription ?? ""])
        lost(peripheral)
    }

    private func lost(_ p: CBPeripheral) {
        guard p === peer else { return }
        connected = false
        rx = nil
        central.connect(p)   // reconnects the moment the Mac is back in range
        search()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == PeerUUID.service }) else {
            // Connected to a Mac whose Orbeat isn't running: wait for Service Changed.
            connected = false
            return
        }
        peripheral.discoverCharacteristics([PeerUUID.toClient, PeerUUID.toServer], for: svc)
    }

    /// The Mac app quit or relaunched: its GATT table changed under the link.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        onLog?(["src": "peer", "ev": "servicesChanged"])
        connected = false
        rx = nil
        peripheral.discoverServices([PeerUUID.service])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for ch in service.characteristics ?? [] {
            if ch.uuid == PeerUUID.toClient { peripheral.setNotifyValue(true, for: ch) }
            if ch.uuid == PeerUUID.toServer { rx = ch }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == PeerUUID.toClient else { return }
        connected = characteristic.isNotifying && rx != nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == PeerUUID.toClient, let v = characteristic.value,
              let m = PeerWire.decode(v) else { return }
        onMessage?(m)
    }
}
