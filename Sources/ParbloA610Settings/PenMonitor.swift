import AppKit
import Combine
import ParbloA610Core

/// Live pen data for calibration.
///
/// There is no link to the driver here, and none is needed: the driver sends
/// real tablet events, and this is a normal app. It gets the pressure and the
/// tablet coordinates by the same path any editor gets them.
///
/// The monitor is local: events arrive only while the settings window is active.
/// A global one would need its own permission, and calibration happens in this
/// window anyway, so it is not needed.
final class PenMonitor: ObservableObject {
    /// Silence longer than this means the pen is not answering right now. The
    /// driver sends about 120 reports a second while the pen is over the tablet,
    /// so two seconds of nothing is not a gap between reports.
    private static let liveTimeout: TimeInterval = 2

    /// Pressure as the app sees it — already after the driver's pressure curve.
    @Published private(set) var pressure: Double = 0
    /// Coordinates in tablet units, before any conversion.
    @Published private(set) var tabletPoint: CGPoint?
    @Published private(set) var isDrawing = false
    /// Whether pen events are arriving **now**. A flag that is only ever set to
    /// true keeps saying "the pen answers" long after the tablet was unplugged.
    @Published private(set) var isLive = false
    /// Seconds since the last pen event, or nil while there has been none. The
    /// ticker republishes it every second, so the window keeps showing the
    /// current number between redraws.
    @Published private(set) var secondsSinceEvent: Int?

    private var monitor: Any?
    private var ticker: Timer?
    private var lastEventAt: Date?

    func start() {
        guard monitor == nil else { return }
        for window in NSApp.windows { window.acceptsMouseMovedEvents = true }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handle(event)
            return event
        }
        // One tick a second, and only while the window is open. It is the only
        // thing that can turn `isLive` back off: a tablet that went away goes
        // silent, and silence carries no event to react to.
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        ticker?.invalidate()
        ticker = nil
        isLive = false
        pressure = 0
        isDrawing = false
        tabletPoint = nil

        // The age of the last event goes too. Kept, it would be counted from an
        // event of the previous session, and the window would report a silence
        // nobody was listening to: the monitor was off all that time.
        lastEventAt = nil
        secondsSinceEvent = nil
    }

    private func handle(_ event: NSEvent) {
        // A mouse event with the tablet subtype is the pen.
        guard event.subtype == .tabletPoint else { return }
        lastEventAt = Date()
        isLive = true
        secondsSinceEvent = 0
        pressure = Double(event.pressure)
        tabletPoint = CGPoint(x: event.absoluteX, y: event.absoluteY)
        switch event.type {
        case .leftMouseDown: isDrawing = true
        case .leftMouseUp: isDrawing = false
        default: break
        }
    }

    private func tick() {
        guard let last = lastEventAt else { return }
        let silence = Date().timeIntervalSince(last)
        secondsSinceEvent = Int(silence)
        guard isLive, silence > Self.liveTimeout else { return }

        // The pen left, or the driver stopped. The bar and the orange marker in
        // the area map are drawn as live readings, so holding the last values
        // would show something nothing is sending any more.
        isLive = false
        pressure = 0
        isDrawing = false
        tabletPoint = nil
    }
}
