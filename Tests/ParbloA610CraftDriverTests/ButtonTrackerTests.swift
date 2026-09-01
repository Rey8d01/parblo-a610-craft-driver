import CoreGraphics
import Testing

@testable import ParbloA610Core
@testable import ParbloA610CraftDriver

private let defaults = Config.PenButtons()  // barrel1 = right, barrel2 = middle

private func pen(tip: Bool = false, b1: Bool = false, b2: Bool = false) -> PenState {
    PenState(tipSwitch: tip, barrel1: b1, barrel2: b2, inRange: true)
}

@Suite("Pen button state")
struct ButtonTrackerTests {

    @Test("pen in the air gives movement only")
    func hover() {
        var t = ButtonTracker()
        #expect(t.update(pen(), buttons: defaults) == [.move])
        #expect(t.heldButton == nil)
    }

    @Test("normal stroke: press, drag, release")
    func stroke() {
        var t = ButtonTracker()
        #expect(t.update(pen(tip: true), buttons: defaults) == [.press(.left)])
        #expect(t.update(pen(tip: true), buttons: defaults) == [.drag(.left)])
        #expect(t.update(pen(), buttons: defaults) == [.release(.left), .move])
        #expect(t.heldButton == nil)
    }

    @Test("a barrel button does not swap the button mid-stroke")
    func barrelDoesNotHijackStroke() {
        var t = ButtonTracker()
        #expect(t.update(pen(tip: true), buttons: defaults) == [.press(.left)])
        #expect(t.update(pen(tip: true, b1: true), buttons: defaults) == [.drag(.left)])
    }

    /// Bug found by the audit: the button was released only when all inputs went
    /// up at the same time. A pen lifted off the tablet with the barrel button
    /// held left the left button pressed, and the stroke went on in the air.
    @Test("pen tip lifted while a barrel is held: the left button must be released")
    func liftingTipWhileBarrelHeldReleasesLeft() {
        var t = ButtonTracker()
        _ = t.update(pen(tip: true), buttons: defaults)
        _ = t.update(pen(tip: true, b1: true), buttons: defaults)

        let actions = t.update(pen(b1: true), buttons: defaults)

        #expect(actions.first == .release(.left))
        #expect(!actions.contains(.drag(.left)))
        #expect(t.heldButton == .right)
    }

    /// The mirror case of the same bug.
    @Test("barrel released while the tip is down: the right button must be released")
    func releasingBarrelWhileTipDownReleasesRight() {
        var t = ButtonTracker()
        #expect(t.update(pen(b1: true), buttons: defaults) == [.press(.right)])
        #expect(t.update(pen(tip: true, b1: true), buttons: defaults) == [.drag(.right)])

        let actions = t.update(pen(tip: true), buttons: defaults)

        #expect(actions.first == .release(.right))
        #expect(!actions.contains(.drag(.right)))
        #expect(t.heldButton == .left)
    }

    @Test("the upper barrel gives the middle button")
    func upperBarrel() {
        var t = ButtonTracker()
        #expect(t.update(pen(b2: true), buttons: defaults) == [.press(.center)])
    }

    @Test("a barrel turned off in settings does not block the tip")
    func disabledBarrelFallsBackToTip() {
        let off = Config.PenButtons(barrel1: .none, barrel2: .none)
        var t = ButtonTracker()
        #expect(t.update(pen(tip: true, b1: true), buttons: off) == [.press(.left)])
    }

    /// `IOLLEvent.h` says this field is a mouse-button mask: bit 0 left, bit 1
    /// right, bit 2 middle. Built from the raw pen state it made the event
    /// contradict itself — a left button down whose mask claimed the right one.
    @Test("the tablet button mask follows the button we really press")
    func maskFollowsTheEmittedButton() {
        #expect(tabletButtonMask(for: nil) == 0)
        #expect(tabletButtonMask(for: .left) == 0x0001)
        #expect(tabletButtonMask(for: .right) == 0x0002)
        #expect(tabletButtonMask(for: .center) == 0x0004)
    }

    /// With the lower barrel turned off the pen holds nothing, so the mask must
    /// be empty even though the barrel is physically pressed.
    @Test("a barrel turned off reports no button in the mask")
    func disabledBarrelReportsNoButton() {
        let off = Config.PenButtons(barrel1: .none, barrel2: .none)
        var t = ButtonTracker()
        #expect(t.update(pen(b1: true), buttons: off) == [.move])
        #expect(tabletButtonMask(for: t.heldButton) == 0)
    }

    /// Remapped to the left click, the lower barrel must report the left button.
    /// Its bit carries the name of the right one, which is where the bug came from.
    @Test("a remapped barrel reports the button it was mapped to")
    func remappedBarrelReportsMappedButton() {
        let mapped = Config.PenButtons(barrel1: .leftClick, barrel2: .middleClick)
        var t = ButtonTracker()
        #expect(t.update(pen(b1: true), buttons: mapped) == [.press(.left)])
        #expect(tabletButtonMask(for: t.heldButton) == 0x0001)
    }

    @Test("leaving the range releases the held button")
    func leavingProximityReleases() {
        var t = ButtonTracker()
        _ = t.update(pen(tip: true), buttons: defaults)
        #expect(t.releaseHeld() == .release(.left))
        #expect(t.heldButton == nil)
        #expect(t.releaseHeld() == nil)
    }
}
