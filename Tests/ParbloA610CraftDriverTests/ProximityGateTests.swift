import Foundation
import Testing

@testable import ParbloA610CraftDriver

/// This is the transition that broke Krita: the driver believed the first
/// "the pen left" report, and with a barrel button held the button was released
/// and pressed again several times a second.
@Suite("Pen proximity")
struct ProximityGateTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// Both numbers come from the measurement of 31.08.2026: 29 blinks ended
    /// within 118 ms, every real lift lasted at least 226 ms. A threshold outside
    /// that band brings back either the flicker or a pen that hangs in the range
    /// after it is gone.
    @Test("the threshold stays between the measured blinks and the real lifts")
    func thresholdMatchesTheMeasurement() {
        #expect(ProximityGate.grace > 0.118)
        #expect(ProximityGate.grace < 0.226)
    }

    @Test("the first report from a pen in range brings it into the range")
    func entersOnce() {
        var gate = ProximityGate()
        #expect(gate.report(inRange: true, now: start) == .enter)
        #expect(gate.report(inRange: true, now: start + 0.008) == .stay)
        #expect(gate.inProximity)
    }

    /// The pen crossed the top of the sensing height and came back 50 ms later.
    @Test("a gap shorter than the countdown leaves no trace")
    func shortGapIsNotALeaving() {
        var gate = ProximityGate()
        _ = gate.report(inRange: true, now: start)

        #expect(gate.report(inRange: false, now: start) == .wait)
        #expect(gate.hasLeft(by: start + 0.05) == false)

        #expect(gate.report(inRange: true, now: start + 0.05) == .stay)
        #expect(gate.inProximity)
        // Nothing is pending any more: a timer firing late must find nothing to do.
        #expect(gate.hasLeft(by: start + 10) == false)
    }

    @Test("silence after the announcement ends the range")
    func silenceEndsTheRange() {
        var gate = ProximityGate()
        _ = gate.report(inRange: true, now: start)
        _ = gate.report(inRange: false, now: start)

        // Either side of the threshold, a millisecond away from it: `Date`
        // arithmetic on 0.15 does not land on it exactly.
        #expect(gate.hasLeft(by: start + 0.149) == false)
        #expect(gate.hasLeft(by: start + 0.151) == true)
    }

    /// The tablet repeats the announcement while the pen stays away. Counting
    /// from the newest one would push the deadline forward for ever.
    @Test("the countdown runs from the first announcement")
    func countdownStartsOnce() {
        var gate = ProximityGate()
        _ = gate.report(inRange: true, now: start)
        _ = gate.report(inRange: false, now: start)
        #expect(gate.report(inRange: false, now: start + 0.1) == .wait)
        #expect(gate.hasLeft(by: start + 0.151) == true)
    }

    /// `wait` is the whole answer to a barrel button held through a blink: the
    /// caller uses nothing from that report, and the button stays down. The report
    /// says pressure zero with every button bit clear, so using it would release
    /// the button and press it again when the pen came back.
    @Test("the report that announces the leaving is never a usable one")
    func announcementIsNeverUsable() {
        var gate = ProximityGate()
        _ = gate.report(inRange: true, now: start)
        for step in 0...5 {
            let answer = gate.report(inRange: false, now: start + Double(step) * 0.008)
            #expect(answer == .wait)
        }
    }

    @Test("a pen that already left is ignored until it comes back")
    func idleUntilItReturns() {
        var gate = ProximityGate()
        _ = gate.report(inRange: true, now: start)
        _ = gate.report(inRange: false, now: start)
        gate.left()

        #expect(gate.inProximity == false)
        #expect(gate.report(inRange: false, now: start + 0.2) == .idle)
        #expect(gate.hasLeft(by: start + 10) == false)
        #expect(gate.report(inRange: true, now: start + 1) == .enter)
    }

    /// The silence timeout and the unplug path both go through `left()`, and a
    /// countdown left standing there would fire into an empty range.
    @Test("leaving clears the pending countdown")
    func leavingClearsTheCountdown() {
        var gate = ProximityGate()
        _ = gate.report(inRange: true, now: start)
        _ = gate.report(inRange: false, now: start)
        gate.left()
        #expect(gate.hasLeft(by: start + 1) == false)
    }
}
