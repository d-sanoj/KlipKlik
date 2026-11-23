import CoreGraphics
import Foundation

/// Spots a deliberate left-right shake of the pointer during a drag.
///
/// A shake is a run of horizontal direction changes, each after a real stroke,
/// packed into a short window. Strokes shorter than `minimumStroke` are hand
/// tremor or a drag that is simply wandering and are ignored, which is what
/// keeps an ordinary drag across the screen from ever counting.
struct ShakeDetector {
    /// Points travelled in one direction before a reversal counts.
    var minimumStroke: CGFloat = 40
    /// Reversals needed: three is left-right-left-right.
    var reversalsNeeded = 3
    /// How quickly the reversals have to follow each other.
    var window: TimeInterval = 0.7

    private var anchorX: CGFloat?
    /// +1 moving right, -1 moving left, 0 before the first stroke.
    private var direction: CGFloat = 0
    private var reversals: [TimeInterval] = []

    mutating func reset() {
        anchorX = nil
        direction = 0
        reversals = []
    }

    /// Feeds one pointer sample. Returns true on the sample that completes a shake.
    mutating func add(x: CGFloat, at time: TimeInterval) -> Bool {
        guard let anchor = anchorX else {
            anchorX = x
            return false
        }

        let travel = x - anchor
        guard abs(travel) >= minimumStroke else {
            // Still within the current stroke; follow its far end so the next
            // reversal is measured from the turning point.
            if direction != 0, (x - anchor) * direction > 0 { anchorX = x }
            return false
        }

        let newDirection: CGFloat = travel > 0 ? 1 : -1
        if direction != 0, newDirection != direction {
            reversals.append(time)
        }
        direction = newDirection
        anchorX = x

        reversals.removeAll { time - $0 > window }
        if reversals.count >= reversalsNeeded {
            reset()
            return true
        }
        return false
    }
}
