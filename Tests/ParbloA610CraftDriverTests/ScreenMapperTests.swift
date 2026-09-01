import CoreGraphics
import Testing

@testable import ParbloA610Core

private let tablet = TabletParams(
    xMax: 40000, yMax: 24000, pressureMax: 2047, resolution: 4000)
private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)

private func mapper(_ change: (inout Config) -> Void = { _ in }, screen: CGRect = laptop)
    -> ScreenMapper
{
    var config = Config()
    change(&config)
    return ScreenMapper(params: tablet, config: config, displayBounds: screen)
}

@Suite("Tablet to screen mapping")
struct ScreenMapperTests {

    @Test("the tablet centre maps to the screen centre")
    func centre() {
        let p = mapper().point(x: 20000, y: 12000)
        #expect(abs(p.x - 756) < 0.5)
        #expect(abs(p.y - 491) < 0.5)
    }

    /// The main reason letterboxing exists at all: the tablet is 5:3 and the screen
    /// is about 1.54:1. If the scale differs per axis, a circle becomes an ellipse.
    @Test("the scale is equal on both axes: a circle stays a circle")
    func uniformScale() {
        let m = mapper()
        let origin = m.point(x: 20000, y: 12000)
        let movedX = m.point(x: 21000, y: 12000)
        let movedY = m.point(x: 20000, y: 13000)
        #expect(abs((movedX.x - origin.x) - (movedY.y - origin.y)) < 0.01)
    }

    @Test("without the aspect lock the axes scale differently")
    func stretchedWhenLockDisabled() {
        let m = mapper { $0.lockAspectRatio = false }
        let origin = m.point(x: 20000, y: 12000)
        let movedX = m.point(x: 21000, y: 12000)
        let movedY = m.point(x: 20000, y: 13000)
        #expect(abs((movedX.x - origin.x) - (movedY.y - origin.y)) > 1)
    }

    @Test("the tablet edges keep the cursor on the screen")
    func clamping() {
        let m = mapper()
        for (x, y) in [(0, 0), (40000, 24000), (0, 24000), (40000, 0)] {
            let p = m.point(x: x, y: y)
            #expect(p.x >= 0 && p.x <= 1512)
            #expect(p.y >= 0 && p.y <= 982)
        }
    }

    /// The display coordinate space is half-open: a point exactly on the right
    /// edge already belongs to the next screen, so the pen near the edge would
    /// move the cursor to another monitor.
    @Test("the screen edge does not spill onto the next display")
    func edgeStaysOnDisplay() {
        let m = mapper()
        let corner = m.point(x: 40000, y: 24000)
        #expect(corner.x < 1512)
        #expect(corner.y < 982)
        // The last pixel is still reachable, so the range survives the clamp.
        #expect(corner.x > 1511)
        #expect(corner.y > 981)
    }

    @Test("180° rotation flips both axes")
    func rotate180() {
        let normal = mapper().point(x: 4000, y: 3000)
        let flipped = mapper { $0.orientation = 180 }.point(x: 36000, y: 21000)
        #expect(abs(normal.x - flipped.x) < 0.5)
        #expect(abs(normal.y - flipped.y) < 0.5)
    }

    @Test("90° rotation swaps the axes")
    func rotate90() {
        let m = mapper { $0.orientation = 90 }
        let origin = m.point(x: 20000, y: 12000)
        let alongX = m.point(x: 26000, y: 12000)
        let alongY = m.point(x: 20000, y: 6000)
        // moving along tablet X goes down the screen, along Y it goes right
        #expect(alongX.y > origin.y)
        #expect(abs(alongX.x - origin.x) < 0.5)
        #expect(alongY.x > origin.x)
        #expect(abs(alongY.y - origin.y) < 0.5)
    }

    @Test("every rotation keeps the centre in the centre")
    func rotationKeepsCentre() {
        for angle in [0, 90, 180, 270] {
            let p = mapper { $0.orientation = angle }.point(x: 20000, y: 12000)
            #expect(abs(p.x - 756) < 0.5, "rotation \(angle)°")
            #expect(abs(p.y - 491) < 0.5, "rotation \(angle)°")
        }
    }

    @Test("the active area from settings narrows the used part of the tablet")
    func activeArea() {
        let m = mapper { $0.activeArea = Config.Area(x: 0.25, y: 0.25, width: 0.5, height: 0.5) }
        let centre = m.point(x: 20000, y: 12000)
        #expect(abs(centre.x - 756) < 0.5)
        #expect(abs(centre.y - 491) < 0.5)
        // a quarter of the tablet from the centre now moves the cursor further away
        let full = mapper().point(x: 25000, y: 12000)
        let narrowed = m.point(x: 25000, y: 12000)
        #expect(narrowed.x > full.x)
    }

    @Test("a portrait screen also keeps the scale equal")
    func portraitDisplay() {
        let m = mapper(screen: CGRect(x: 0, y: 0, width: 982, height: 1512))
        let origin = m.point(x: 20000, y: 12000)
        let movedX = m.point(x: 21000, y: 12000)
        let movedY = m.point(x: 20000, y: 13000)
        #expect(abs((movedX.x - origin.x) - (movedY.y - origin.y)) < 0.01)
    }

    @Test("a screen with an offset origin is handled")
    func offsetDisplay() {
        let m = mapper(screen: CGRect(x: 1512, y: -300, width: 1920, height: 1080))
        let p = m.point(x: 20000, y: 12000)
        #expect(abs(p.x - (1512 + 960)) < 0.5)
        #expect(abs(p.y - (-300 + 540)) < 0.5)
    }
}
