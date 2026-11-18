import Testing
@testable import BasitCutCore

struct RationalTimeTests {
    @Test func equalityComparesRationalValues() {
        #expect(RationalTime(value: 1, timescale: 2) == RationalTime(value: 300, timescale: 600))
        #expect(Set([RationalTime(value: 1, timescale: 2), RationalTime(value: 3, timescale: 6)]).count == 1)
    }

    @Test func additionAcrossTimescalesIsExact() {
        // 1/30 + 1001/30000 (one NTSC frame) = 2001/30000
        let sum = RationalTime(value: 1, timescale: 30) + RationalTime(value: 1001, timescale: 30000)
        #expect(sum == RationalTime(value: 2001, timescale: 30000))
    }

    @Test func repeatedAdditionDoesNotDrift() {
        let frame = RationalTime(value: 1001, timescale: 30000)
        var total = RationalTime.zero
        for _ in 0..<30_000 { total += frame }
        #expect(total == RationalTime.seconds(1001))
    }

    @Test func subtractionAndNegation() {
        #expect(s(5) - s(7) == -s(2))
        #expect(s(2) < s(2.5))
    }

    @Test func flooringToFrames() {
        let frame = RationalTime(value: 1, timescale: 30)
        #expect(s(1.05).floored(toMultipleOf: frame) == RationalTime(value: 31, timescale: 30))
        #expect(s(1).floored(toMultipleOf: frame) == s(1))
        #expect(RationalTime(value: -1, timescale: 60).floored(toMultipleOf: frame) == RationalTime(value: -1, timescale: 30))
    }

    @Test func roundingToFrames() {
        let frame = RationalTime(value: 1, timescale: 30)
        #expect(s(1.05).rounded(toMultipleOf: frame) == RationalTime(value: 32, timescale: 30))   // 31.5 frames → 32
        #expect(s(1.04).rounded(toMultipleOf: frame) == RationalTime(value: 31, timescale: 30))
    }

    @Test func halving() {
        #expect(RationalTime.seconds(1).divided(by: 2) == s(0.5))
        #expect(RationalTime(value: 1, timescale: 5).divided(by: 2) == RationalTime(value: 1, timescale: 10))
    }

    @Test func secondsConversion() {
        #expect(RationalTime(seconds: 1.5).seconds == 1.5)
        #expect(RationalTime(value: 1001, timescale: 30000).seconds == 1001.0 / 30000.0)
    }
}
