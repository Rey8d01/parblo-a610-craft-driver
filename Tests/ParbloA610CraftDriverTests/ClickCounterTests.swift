import CoreGraphics
import Foundation
import Testing

@testable import ParbloA610CraftDriver

/// The count goes into `mouseEventClickState`, and apps act on the second click:
/// Finder opens a file, a text view starts renaming it. A wrong count here is a
/// wrong action in someone else's program.
@Suite("Pen click count")
struct ClickCounterTests {
    private let point = CGPoint(x: 100, y: 100)
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("two quick taps in one place make a double click")
    func doubleClick() {
        var counter = ClickCounter()
        #expect(counter.press(at: point, button: .left, interval: 0.5, now: start) == 1)
        #expect(
            counter.press(at: point, button: .left, interval: 0.5, now: start + 0.2) == 2)
    }

    /// The counter used to be shared by all buttons: a right click with the
    /// barrel button, then a tip touch in the same place, and the tip arrived as
    /// a left double click.
    @Test("a different button starts the count again")
    func anotherButtonResets() {
        var counter = ClickCounter()
        #expect(counter.press(at: point, button: .right, interval: 0.5, now: start) == 1)
        #expect(
            counter.press(at: point, button: .left, interval: 0.5, now: start + 0.2) == 1)
    }

    @Test("a slow second tap is a first click again")
    func slowTapResets() {
        var counter = ClickCounter()
        _ = counter.press(at: point, button: .left, interval: 0.5, now: start)
        #expect(
            counter.press(at: point, button: .left, interval: 0.5, now: start + 0.6) == 1)
    }

    /// The interval comes from System Settings. A tap that is slow for the
    /// default is quick for someone who set a long one.
    @Test("the system interval decides what counts as quick")
    func intervalComesFromOutside() {
        var counter = ClickCounter()
        _ = counter.press(at: point, button: .left, interval: 1.0, now: start)
        #expect(
            counter.press(at: point, button: .left, interval: 1.0, now: start + 0.6) == 2)
    }

    @Test("a tap far away is a first click again")
    func farTapResets() {
        var counter = ClickCounter()
        _ = counter.press(at: point, button: .left, interval: 0.5, now: start)
        let far = CGPoint(x: point.x + 40, y: point.y)
        #expect(counter.press(at: far, button: .left, interval: 0.5, now: start + 0.2) == 1)
    }

    @Test("the count stops at three")
    func stopsAtThree() {
        var counter = ClickCounter()
        for step in 0...5 {
            _ = counter.press(
                at: point, button: .left, interval: 0.5, now: start + Double(step) * 0.1)
        }
        #expect(counter.count == 3)
    }
}
