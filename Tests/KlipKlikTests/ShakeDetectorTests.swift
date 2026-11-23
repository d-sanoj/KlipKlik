import CoreGraphics
import Testing
@testable import KlipKlik

@Suite struct ShakeDetectorTests {
    /// Feeds x positions 40 ms apart; returns the index that completed a shake.
    private func run(_ xs: [CGFloat]) -> Int? {
        var detector = ShakeDetector()
        for (index, x) in xs.enumerated() where detector.add(x: x, at: Double(index) * 0.04) {
            return index
        }
        return nil
    }

    @Test func leftRightLeftRightIsAShake() {
        #expect(run([0, 60, 0, 60, 0]) == 4)
    }

    @Test func aLongStraightDragIsNot() {
        #expect(run(stride(from: 0, through: 800, by: 20).map { CGFloat($0) }) == nil)
    }

    @Test func smallWobbleIsNot() {
        #expect(run([0, 10, 0, 12, 2, 11, 0, 9, 1]) == nil)
    }

    @Test func slowReversalsDoNotAddUp() {
        var detector = ShakeDetector()
        let samples: [(CGFloat, Double)] = [(0, 0), (60, 0.5), (0, 1.5), (60, 2.5), (0, 3.5)]
        let fired = samples.contains { detector.add(x: $0.0, at: $0.1) }
        #expect(!fired)
    }

    @Test func reversalIsMeasuredFromTheTurningPoint() {
        // Drifts right to 200, then shakes around there.
        #expect(run([0, 50, 100, 150, 200, 150, 200, 150]) != nil)
    }
}
