import Foundation

/// Decides when the pen has really left the tablet.
///
/// The device announces the leaving with bit 6 of the flags byte, and it sends
/// that announcement every time the pen crosses the top of the sensing height —
/// including the times the hand brings it straight back down. Believing the first
/// one made proximity flicker several times a second while hovering, and with a
/// barrel button held the button was released and pressed again on every blink.
/// Krita latched its canvas pan on that.
///
/// So an announcement starts a countdown, and any report from a pen in range
/// cancels it. The rule lives here, apart from the event building, because the
/// numbers below come from a measurement and a later edit must not lose them.
struct ProximityGate {
    /// How long the pen may be out of range before it counts as gone.
    ///
    /// Measured 31.08.2026 over 51 exits: 29 of them ended within 118 ms — the
    /// pen was raised just above the sensing height and came back — while every
    /// real lift lasted at least 226 ms. The band between the two is empty, so
    /// the threshold sits in it. `ProximityGateTests` holds it there.
    static let grace: TimeInterval = 0.15

    /// What the caller should do with the report it just passed in.
    enum Step: Equatable {
        /// The pen came into range with this report.
        case enter
        /// The pen is in range; the report carries real data.
        case stay
        /// The report only announces the leaving. Nothing in it may be used: the
        /// pressure is zero and every button bit is clear, so acting on it would
        /// release a button the hand is still holding.
        case wait
        /// The pen is out of range and already counted as gone.
        case idle
    }

    private(set) var inProximity = false
    /// When the device announced the leaving; nil while the pen is here.
    private var leavingSince: Date?

    mutating func report(inRange: Bool, now: Date) -> Step {
        if inRange {
            leavingSince = nil
            if inProximity { return .stay }
            inProximity = true
            return .enter
        }
        guard inProximity else { return .idle }
        // The countdown runs from the first announcement. A stream of them means
        // the pen stayed away, so restarting it on each one would never end.
        if leavingSince == nil { leavingSince = now }
        return .wait
    }

    /// Whether the countdown has run out. Asked when the timer fires: the pen may
    /// have come back while the timer was waiting in the queue.
    func hasLeft(by now: Date) -> Bool {
        guard inProximity, let since = leavingSince else { return false }
        return now.timeIntervalSince(since) >= Self.grace
    }

    /// The pen is gone — by the countdown, by the silence timeout, or because the
    /// tablet was unplugged.
    mutating func left() {
        inProximity = false
        leavingSince = nil
    }
}
