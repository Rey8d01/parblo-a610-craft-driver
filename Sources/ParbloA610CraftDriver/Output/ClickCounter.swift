import CoreGraphics
import Foundation

/// Counts the presses that add up to a double click.
///
/// The count belongs to one button in one place: it grows only when the same
/// button goes down again, close by, inside the system double-click interval.
/// A counter shared by all buttons turned a right click followed by a tip touch
/// into a left double click, and apps acted on it — a second click opens a file
/// or starts renaming it.
struct ClickCounter {
    /// How far apart two presses may be and still count as one place, in points.
    /// The pen shakes a little even when the hand means the same spot.
    private static let radius: CGFloat = 8
    /// Menus and text views read up to a triple click; deeper counts mean nothing.
    private static let maxCount: Int64 = 3

    private var lastAt = Date.distantPast
    private var lastPoint = CGPoint.zero
    private var lastButton: CGMouseButton?

    /// `interval` is the system double-click time. The owner sets it in System
    /// Settings, and a fixed value here would disagree with every mouse on the
    /// machine: a slow interval would break their double clicks with the pen.
    mutating func press(
        at point: CGPoint, button: CGMouseButton, interval: TimeInterval, now: Date = Date()
    ) -> Int64 {
        let close = hypot(point.x - lastPoint.x, point.y - lastPoint.y) < Self.radius
        let quick = now.timeIntervalSince(lastAt) < interval
        let sameButton = lastButton == button

        count = (sameButton && close && quick) ? min(count + 1, Self.maxCount) : 1
        lastAt = now
        lastPoint = point
        lastButton = button
        return count
    }

    /// The count of the last press. Move, drag and release events carry it too:
    /// an app matches the release to the press by this number.
    private(set) var count: Int64 = 1
}
