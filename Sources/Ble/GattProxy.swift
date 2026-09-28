import Foundation
import CoreBluetooth

/// Transparent GATT mirror: every service the hub discovers upstream is
/// re-published 1:1 as a local BLE peripheral ("Orbeat"). Downstream clients
/// (another Orbeat, Zwift on Apple TV, a bike computer) see the same UUIDs,
/// properties and bytes as if they were on the sensor itself — reads, writes,
/// notifications and indications all forward raw, no per-sensor code.
///
/// One source per service UUID (latest mirrored wins) — a second HR strap
/// can't coexist with the first, same as the hub's one-slot-per-type policy.
///
/// Also hosts fixed local services (the Mac's end of the peer link) on the same
/// peripheral manager: one manager per app keeps advertising predictable.
final class GattProxy: NSObject, CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager?
    /// Mirrored service by UUID, and which upstream peripheral it came from.
    private var services: [CBUUID: CBMutableService] = [:]
    private var sources: [CBUUID: CBPeripheral] = [:]
    /// Char UUID → upstream (peripheral, characteristic) / downstream mirror.
    private var upstream: [CBUUID: (CBPeripheral, CBCharacteristic)] = [:]
    private var mirrors: [CBUUID: CBMutableCharacteristic] = [:]
    /// Downstream reads waiting for the upstream value, FIFO per char.
    private var pendingReads: [CBUUID: [CBATTRequest]] = [:]
    /// Latest value per char that updateValue refused (transmit queue full),
    /// re-sent from peripheralManagerIsReady. Latest wins: a sensor sample
    /// that's a second old is worth less than the one that just arrived.
    private var backlog: [CBUUID: Data] = [:]
    /// Diagnostics for the hub's log sink.
    var onLog: (([String: Any]) -> Void)?
    /// A downstream client wrote through us (char UUID, bytes) — after forwarding.
    var onDownstreamWrite: ((CBUUID, Data) -> Void)?

    /// Fixed services published whether or not sensor sharing is on.
    private var hosted: [CBMutableService] = []
    private var hostedChars: Set<CBUUID> = []
    /// Hosted-service traffic: writes, (un)subscribes, transmit queue drained.
    var onHostedWrite: ((CBATTRequest) -> Void)?
    var onHostedSubscribers: ((Int) -> Void)?
    var onReady: (() -> Void)?
    private var hostedSubscribers: Set<UUID> = [] {
        didSet { if hostedSubscribers != oldValue { onHostedSubscribers?(hostedSubscribers.count) } }
    }

    /// Sensor sharing: mirror upstream services to third-party clients.
    var enabled = UserDefaults.standard.bool(forKey: "rebroadcast") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "rebroadcast")
            guard enabled != oldValue else { return }
            if let live { enabled ? services.values.forEach(live.add) : services.values.forEach(live.remove) }
            sync()
        }
    }

    override init() {
        super.init()
        sync()
    }

    /// Publish a fixed service (call once, before or after power-on).
    func host(_ service: CBMutableService) {
        hosted.append(service)
        (service.characteristics ?? []).forEach { hostedChars.insert($0.uuid) }
        live?.add(service)
        sync()
    }

    /// Notify hosted-char subscribers. False = transmit queue full; retry on `onReady`.
    func update(_ data: Data, for ch: CBMutableCharacteristic) -> Bool {
        live?.updateValue(data, for: ch, onSubscribedCentrals: nil) ?? false
    }

    /// Run the manager while anything needs it; (re)advertise the current set.
    private func sync() {
        if enabled || !hosted.isEmpty {
            if manager == nil { manager = CBPeripheralManager(delegate: self, queue: .main) }
            advertise()
        } else {
            manager?.stopAdvertising()
            manager?.removeAllServices()
            manager = nil
        }
    }

    private static let mirrorable: CBCharacteristicProperties =
        [.read, .write, .writeWithoutResponse, .notify, .indicate]

    // MARK: Upstream → mirror table

    /// (Re)publish an upstream service once its characteristics are known.
    func mirror(_ service: CBService, of peripheral: CBPeripheral) {
        var chars: [CBMutableCharacteristic] = []
        for ch in service.characteristics ?? [] {
            let props = ch.properties.intersection(Self.mirrorable)
            guard !props.isEmpty else { continue }
            var perms: CBAttributePermissions = []
            if !props.isDisjoint(with: [.read, .notify, .indicate]) { perms.insert(.readable) }
            if !props.isDisjoint(with: [.write, .writeWithoutResponse]) { perms.insert(.writeable) }
            let m = CBMutableCharacteristic(type: ch.uuid, properties: props, value: nil, permissions: perms)
            chars.append(m)
            upstream[ch.uuid] = (peripheral, ch)
            mirrors[ch.uuid] = m
        }
        guard !chars.isEmpty else { return }
        let svc = CBMutableService(type: service.uuid, primary: true)
        svc.characteristics = chars
        // Swap just this service: removeAllServices() would drop every
        // downstream subscription on the other mirrored services.
        if let old = services[service.uuid] { sharing?.remove(old) }
        services[service.uuid] = svc
        sources[service.uuid] = peripheral
        sharing?.add(svc)
        advertise()
    }

    /// Upstream gone: withdraw everything it backed (downstream sees Service Changed).
    func unmirror(_ peripheral: CBPeripheral) {
        for (uuid, p) in sources where p === peripheral {
            if let svc = services[uuid] { sharing?.remove(svc) }
            services[uuid] = nil; sources[uuid] = nil
        }
        // Sweep by owner, not by service: a char UUID may since have been
        // re-mirrored from another peripheral (2A65 on two power sources).
        for (uuid, (p, _)) in upstream where p === peripheral {
            upstream[uuid] = nil; mirrors[uuid] = nil; backlog[uuid] = nil
            fail(reads: uuid)
        }
        advertise()
    }

    private var live: CBPeripheralManager? {
        manager.flatMap { $0.state == .poweredOn ? $0 : nil }
    }
    /// Live manager, only while mirrored services should be published.
    private var sharing: CBPeripheralManager? { enabled ? live : nil }

    /// Re-advertise the current set. Hosted services first, then mirrored
    /// 16-bit UUIDs only: a mirrored 128-bit UUID eats 18 of the 31 bytes and
    /// pushes 180D/1818 into Apple's overflow area, invisible to non-Apple
    /// clients. Connected clients still discover the 128-bit services.
    private func advertise() {
        guard let live else { return }
        live.stopAdvertising()
        let short = enabled
            ? services.keys.filter { $0.data.count == 2 }.sorted { $0.uuidString < $1.uuidString } : []
        let uuids = hosted.map(\.uuid) + short
        guard !uuids.isEmpty else { return }
        live.startAdvertising([
            CBAdvertisementDataLocalNameKey: "Orbeat",
            CBAdvertisementDataServiceUUIDsKey: uuids,
        ])
    }

    private func fail(reads uuid: CBUUID) {
        for r in pendingReads.removeValue(forKey: uuid) ?? [] {
            manager?.respond(to: r, withResult: .unlikelyError)
        }
    }

    // MARK: Upstream traffic → downstream

    /// Notification, indication or read result (or read failure) from the sensor.
    func upstreamUpdated(_ ch: CBCharacteristic, _ data: Data?, error: Error?) {
        guard let data, error == nil else { fail(reads: ch.uuid); return }
        push(ch.uuid, data)
    }

    /// Deliver a value for a mirrored char to downstream (answers pending
    /// reads, notifies subscribers). No-op when the char isn't mirrored.
    func push(_ uuid: CBUUID, _ data: Data) {
        guard let m = mirrors[uuid], let manager else { return }
        if let reqs = pendingReads.removeValue(forKey: uuid) {
            for r in reqs {
                r.value = data.count > r.offset ? data.subdata(in: r.offset..<data.count) : Data()
                manager.respond(to: r, withResult: .success)
            }
        }
        if !manager.updateValue(data, for: m, onSubscribedCentrals: nil) {
            backlog[uuid] = data
            onLog?(["src": "ble", "ev": "proxyQueueFull", "char": uuid.uuidString])
        }
    }

    /// Transmit queue drained: flush what was refused, newest sample per char.
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        for (uuid, data) in backlog {
            guard let m = mirrors[uuid] else { backlog[uuid] = nil; continue }
            if peripheral.updateValue(data, for: m, onSubscribedCentrals: nil) { backlog[uuid] = nil }
        }
        onReady?()
    }

    // MARK: CBPeripheralManagerDelegate (downstream → upstream)

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        onLog?(["src": "ble", "ev": "proxyState", "state": peripheral.state.rawValue])
        guard peripheral.state == .poweredOn else { hostedSubscribers = []; return }
        hosted.forEach { peripheral.add($0) }
        if enabled { services.values.forEach { peripheral.add($0) } }   // mirrored before power-on
        advertise()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        onLog?(["src": "ble", "ev": "proxyService", "uuid": service.uuid.uuidString,
                "err": error?.localizedDescription ?? ""])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        onLog?(["src": "ble", "ev": "proxySubscribe", "char": characteristic.uuid.uuidString])
        if hostedChars.contains(characteristic.uuid) { hostedSubscribers.insert(central.identifier); return }
        guard let (p, ch) = upstream[characteristic.uuid] else { return }
        p.setNotifyValue(true, for: ch)
        // ponytail: never unsubscribes upstream on didUnsubscribeFrom — the hub wants the stream anyway
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        if hostedChars.contains(characteristic.uuid) { hostedSubscribers.remove(central.identifier) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard let (p, ch) = upstream[request.characteristic.uuid] else {
            peripheral.respond(to: request, withResult: .attributeNotFound); return
        }
        pendingReads[ch.uuid, default: []].append(request)
        p.readValue(for: ch)
    }

    /// One batch = one ATT transaction: exactly one respond(), all-or-nothing.
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        if hostedChars.contains(first.characteristic.uuid) {
            requests.forEach { onHostedWrite?($0) }
            peripheral.respond(to: first, withResult: .success)
            return
        }
        guard requests.allSatisfy({ upstream[$0.characteristic.uuid] != nil && $0.value != nil }) else {
            peripheral.respond(to: first, withResult: .writeNotPermitted); return
        }
        for r in requests {
            let (p, ch) = upstream[r.characteristic.uuid]!
            let v = r.value!
            onLog?(["src": "ble", "ev": "proxyWrite", "char": ch.uuid.uuidString,
                    "raw": v.map { String(format: "%02x", $0) }.joined()])
            p.writeValue(v, for: ch, type: ch.properties.contains(.write) ? .withResponse : .withoutResponse)
            onDownstreamWrite?(ch.uuid, v)
        }
        // ponytail: ATT success once forwarded, not once the sensor acks — the
        // hub's own control-point writes share didWriteValueFor, can't pair them.
        peripheral.respond(to: first, withResult: .success)
    }
}
