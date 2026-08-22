import Foundation

/// One decoded Zwift Ride / Play button-frame state change.
/// Zwift-proprietary protocol (plaintext protobuf, no crypto) — UUIDs + format
/// from cagnulein/qdomyos-zwift (src/zwift_play/). Lives inside the BLE
/// component; Core only ever sees the neutral HandlebarInput intents derived
/// from it, never this type.
struct ZwiftButtonFrame {
    let raw: String               // hex, for logging
    let pressed: [String]         // buttons currently held
    let newlyPressed: Set<UInt32> // per-button masks that rose this frame

    /// Any shift-up paddle (left|right); any shift-down paddle.
    static let shiftUp: UInt32   = 0x0100 | 0x1000
    static let shiftDown: UInt32 = 0x0200 | 0x2000
}
