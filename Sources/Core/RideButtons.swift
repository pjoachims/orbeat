import Foundation

/// Neutral handlebar-controller input — what the rider did, regardless of
/// which brand of controller decoded it. Components translate their proprietary
/// button frames into these; app policy (e.g. grade stepping) consumes them.
enum HandlebarInput {
    case shiftUp
    case shiftDown
}
