import Foundation

/// Zwift Protocol trainer commands: what Zwift writes to a Zwift-Ready
/// trainer (KICKR CORE Zwift One, Zwift Hub) on the Zwift service's sync RX
/// char for SIM with virtual shifting. Command 0x04 + HubCommand protobuf;
/// field numbers and init frames from qdomyos-zwift ("Zwift hub.proto",
/// ftmsbike.cpp). The trainer firmware does the physics: it gets the road,
/// the absolute gear ratio and the weights, and measures cadence itself.
enum ZwiftHub {
    /// Sent once after RideOn, as qdomyos-zwift does (0x41: unknown; 0x00:
    /// HubRequest general info, then gear ratio). ponytail: copied, not understood.
    static let initFrames: [[UInt8]] = [[0x41, 0x08, 0x05], [0x00, 0x08, 0x00], [0x00, 0x08, 0x88, 0x04]]

    /// HubCommand.Simulation: wind 0, grade (0.01 %), CWa × 10000, Crr × 100000.
    static func simulation(grade: Int) -> [UInt8] {
        [0x04] + message(4, varint(1, 0) + varint(2, zigzag(grade))
                             + varint(3, UInt64(TrainerMode.zwiftCWa * 10_000))
                             + varint(4, UInt64((TrainerMode.zwiftCrr * 100_000).rounded())))
    }

    /// HubCommand.Physical: gear ratio × 10000, bike and rider weight × 100 (kg).
    static func physical(gearRatio: Double, rider: Rider) -> [UInt8] {
        [0x04] + message(5, varint(2, UInt64((gearRatio * 10_000).rounded()))
                             + varint(4, UInt64(rider.bikeKg * 100)) + varint(5, UInt64(rider.riderKg * 100)))
    }

    /// Both frames for a sim target. Simulation first: qdomyos-zwift found
    /// gear commands ignored until a grade was sent.
    static func frames(_ m: TrainerMode, rider: Rider) -> [[UInt8]]? {
        guard let g = m.sentGrade(difficulty: rider.difficulty), let r = m.gearRatio else { return nil }
        return [simulation(grade: g), physical(gearRatio: r, rider: rider)]
    }

    // Protobuf wire format, just the parts used here.
    private static func zigzag(_ v: Int) -> UInt64 { UInt64(bitPattern: Int64((v << 1) ^ (v >> 63))) }
    private static func varint(_ field: Int, _ v: UInt64) -> [UInt8] { [UInt8(field << 3)] + raw(v) }
    private static func message(_ field: Int, _ body: [UInt8]) -> [UInt8] { [UInt8(field << 3 | 2)] + raw(UInt64(body.count)) + body }
    private static func raw(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat { out.append(UInt8(v & 0x7F) | (v > 0x7F ? 0x80 : 0)); v >>= 7 } while v > 0
        return out
    }
}
