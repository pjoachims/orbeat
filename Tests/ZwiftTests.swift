import Foundation

/// Zwift Ride / Play button-frame decode against hand-built 0x23 frames.
/// Note on semantics: `newlyPressed` holds INDIVIDUAL button masks (bit 8 =
/// leftShiftUp, bit 12 = rightShiftUp, …); the combined shiftUp/shiftDown
/// masks are "any paddle" patterns to test against with bitwise overlap,
/// exactly like the app policy does.
enum ZwiftTests {
    /// Wrap a button bitmap into a 0x23 frame: tag byte 0x08 (field 1, varint).
    private static func frame(_ map: UInt32) -> [UInt8] {
        var v = map
        var payload: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            payload.append(byte)
        } while v != 0
        return [0x23, 0x08] + payload
    }

    static func run() {
        let c = ZwiftRideController()

        // Init baseline IS all-released: an unchanged all-released frame is not
        // a state change.
        check("zwift baseline no change", c.handle(frame(0xFFFFFFFF)) == nil)

        // leftShiftUp pressed (bit 8 CLEAR = pressed) → rising edge.
        let up = c.handle(frame(0xFFFFFEFF))!
        check("zwift shiftUp edge", up.newlyPressed == [256]
            && up.pressed == ["leftShiftUp"], "\(up)")

        // Same bitmap again → unchanged, no frame.
        check("zwift repeat → nil", c.handle(frame(0xFFFFFEFF)) == nil)

        // Release leftShiftUp, press leftShiftDown (bit 9) in one frame.
        let down = c.handle(frame(0xFFFFFDFF))!
        check("zwift shiftDown edge",
              down.newlyPressed.contains(where: { $0 & ZwiftButtonFrame.shiftDown != 0 })
              && !down.newlyPressed.contains(where: { $0 & ZwiftButtonFrame.shiftUp != 0 })
              && down.pressed == ["leftShiftDown"], "\(down)")

        // Fresh controller, all four shifter bits at once → both paddles edge.
        let fresh = ZwiftRideController()
        _ = fresh.handle(frame(0xFFFFFFFF))
        let both = fresh.handle(frame(0xFFFFCCFF))!   // bits 8,9,12,13 cleared
        check("zwift both paddles",
              both.newlyPressed.contains(where: { $0 & ZwiftButtonFrame.shiftUp != 0 })
              && both.newlyPressed.contains(where: { $0 & ZwiftButtonFrame.shiftDown != 0 })
              && both.newlyPressed.count == 4, "\(both)")

        // reset() re-arms edge detection from the all-released baseline.
        c.reset()
        let afterReset = c.handle(frame(0xFFFFFEFF))!
        check("zwift reset re-arms",
              afterReset.newlyPressed.contains(where: { $0 & ZwiftButtonFrame.shiftUp != 0 }))

        // Trailing unknown fields must be skipped without derailing field-1 parse
        // — field 2 (tag 0x10), length-delimited, comes after field 1 here.
        // Bitmap 0xFFFFFCFF (bits 8+9) differs from the current state (0xFFFFFEFF).
        let withTail: [UInt8] = frame(0xFFFFFCFF) + [0x10, 0x02, 0xAA, 0xBB]
        let tail = c.handle(withTail)!
        check("zwift trailing fields skipped",
              tail.newlyPressed.contains(where: { $0 & ZwiftButtonFrame.shiftDown != 0 }), "\(tail)")

        // Wrong first byte → not a button frame.
        check("zwift non-0x23 → nil", c.handle([0x24, 0x08, 0x00]) == nil)
        check("zwift empty → nil", c.handle([]) == nil)
    }
}
