import CoreGraphics
import Foundation

/// Converts tablet coordinates into global display coordinates.
///
/// The bounds come from `CGDisplayBounds`, which already gives the space
/// `CGEventSetLocation` works in: the origin is in the top left corner of the main
/// screen and Y goes down. `NSScreen` puts its origin in the bottom left, and that
/// difference is the usual reason for the "cursor is mirrored vertically" problem.
package struct ScreenMapper {
    private let displayBounds: CGRect
    /// The active area of the tablet — already in rotated coordinates.
    private let area: CGRect
    private let orientation: Int
    private let xMax: Double
    private let yMax: Double

    /// `displayBounds` is set only in tests: otherwise the bounds are taken from
    /// the system, and the result would depend on the connected monitor.
    package init(params: TabletParams, config: Config, displayBounds: CGRect? = nil) {
        let resolved = displayBounds ?? Self.bounds(for: config.display)
        self.displayBounds = resolved
        orientation = config.orientation
        xMax = Double(params.xMax)
        yMax = Double(params.yMax)

        let size =
            (orientation == 90 || orientation == 270)
            ? CGSize(width: yMax, height: xMax)
            : CGSize(width: xMax, height: yMax)

        var rect = CGRect(
            x: config.activeArea.x * size.width,
            y: config.activeArea.y * size.height,
            width: config.activeArea.width * size.width,
            height: config.activeArea.height * size.height)

        if config.lockAspectRatio, rect.width > 0, rect.height > 0, resolved.height > 0 {
            // The tablet is 5:3 (1.667), mac screens are about 1.54–1.60. Without
            // this fix, stretching along one axis turns a circle into an ellipse.
            let target = resolved.width / resolved.height
            let current = rect.width / rect.height
            if current > target {
                let width = rect.height * target
                rect = CGRect(
                    x: rect.midX - width / 2, y: rect.minY,
                    width: width, height: rect.height)
            } else if current < target {
                let height = rect.width / target
                rect = CGRect(
                    x: rect.minX, y: rect.midY - height / 2,
                    width: rect.width, height: height)
            }
        }
        area = rect
    }

    /// The part of the tablet that is really mapped to the screen — in rotated
    /// coordinates. The settings interface needs exactly this one, so it shows the
    /// user the same figure the driver computes.
    package var mappedArea: CGRect { area }

    /// Tablet size with the rotation taken into account.
    package var orientedSize: CGSize {
        (orientation == 90 || orientation == 270)
            ? CGSize(width: yMax, height: xMax)
            : CGSize(width: xMax, height: yMax)
    }

    /// Pen coordinates in the rotated space — to show the point in the same place
    /// where the active area is drawn.
    package func orientedPoint(x: Int, y: Int) -> CGPoint {
        let (rx, ry) = rotate(x: Double(x), y: Double(y))
        return CGPoint(x: rx, y: ry)
    }

    package func point(x: Int, y: Int) -> CGPoint {
        let (rx, ry) = rotate(x: Double(x), y: Double(y))
        let u = area.width > 0 ? clamp((rx - area.minX) / area.width) : 0.5
        let v = area.height > 0 ? clamp((ry - area.minY) / area.height) : 0.5
        // The display coordinate space is half-open: a point exactly on the right
        // or bottom edge already belongs to the next screen. Without this fix, a
        // pen at the very edge would move the cursor to another monitor.
        return CGPoint(
            x: min(displayBounds.minX + u * displayBounds.width, displayBounds.maxX.nextDown),
            y: min(displayBounds.minY + v * displayBounds.height, displayBounds.maxY.nextDown))
    }

    package var describedArea: String {
        String(
            format:
                "screen %.0f×%.0f @ (%.0f,%.0f), tablet area %.0f×%.0f @ (%.0f,%.0f), rotation %d°",
            displayBounds.width, displayBounds.height, displayBounds.minX, displayBounds.minY,
            area.width, area.height, area.minX, area.minY, orientation)
    }

    private func rotate(x: Double, y: Double) -> (Double, Double) {
        switch orientation {
        case 90: return (yMax - y, x)
        case 180: return (xMax - x, yMax - y)
        case 270: return (y, xMax - x)
        default: return (x, y)
        }
    }

    private func clamp(_ value: Double) -> Double { Swift.min(Swift.max(value, 0), 1) }

    private static func bounds(for display: String) -> CGRect {
        guard let index = Int(display) else { return CGDisplayBounds(CGMainDisplayID()) }

        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        guard index >= 0, index < Int(count) else {
            Log.error("Screen #\(index) not found (active: \(count)) — using the main one.")
            return CGDisplayBounds(CGMainDisplayID())
        }
        return CGDisplayBounds(ids[index])
    }
}
