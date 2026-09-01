import AppKit
import CoreGraphics
import Foundation
import ParbloA610Core

/// Turns the `PenState` stream into CoreGraphics tablet events.
///
/// Apps expect a fixed order — proximity first, then points, and the same
/// `deviceID` in every event. Without proximity, Photoshop, Krita and Clip Studio
/// treat the device as a mouse and ignore pressure. Every bug that reached a
/// drawing application came from this file.
final class TabletEventEmitter {
    /// Silence longer than this counts as the pen leaving the range.
    /// Reports come at ~122–148 Hz, that is every 7–8 ms, so a quarter of a
    /// second of silence is definitely not a pause between reports.
    private static let proximityTimeout: TimeInterval = 0.25

    /// What we can do: DeviceID | AbsX | AbsY | Buttons | Pressure.
    /// The `NX_TABLET_CAPABILITY_*` constants from `IOKit/hidsystem/IOLLEvent.h`.
    /// The A610 has no tilt and no rotation, so those bits are not set.
    private static let capabilityMask: Int64 = 0x0001 | 0x0002 | 0x0004 | 0x0040 | 0x0400

    // NX_TABLET_POINTER_* from the same header.
    private static let pointerTypePen: Int64 = 1
    private static let pointerTypeEraser: Int64 = 3

    private let vendorID: Int64
    private let tabletID: Int64
    /// Must be the same in proximity and point events, and stable during the session.
    private let deviceID: Int64 = 1
    /// Pen serial number. The A610 has none, but Qt tells pens apart exactly by it
    /// and reads zero as "no number", so we give a constant value.
    private let penSerial: Int64 = 0x5543_0081

    private let source = CGEventSource(stateID: .hidSystemState)

    private var mapper: ScreenMapper?
    private var curve: PressureCurve?
    private var penButtons = Config.PenButtons()

    /// Where the pen is, and when to stop believing it is still here.
    private var gate = ProximityGate()
    /// The pointer type is fixed when the pen enters the range: leaving must report the
    /// same one, or the app will not match the enter and leave pair.
    private var proximityIsEraser = false
    private var buttons = ButtonTracker()
    private var lastPoint = CGPoint.zero
    private var lastState: PenState?
    private var lastReport = Date.distantPast
    private var exitWork: DispatchWorkItem?
    private var clicks = ClickCounter()
    private var watchdog: DispatchSourceTimer?

    init(vendorID: Int, productID: Int) {
        self.vendorID = Int64(vendorID)
        self.tabletID = Int64(productID)
    }

    // MARK: - Setup

    func configure(params: TabletParams, config: Config) {
        mapper = ScreenMapper(params: params, config: config)
        curve = PressureCurve(pressure: config.pressure, maxRaw: params.pressureMax)
        penButtons = config.penButtons
        Log.info("Mapping: \(mapper!.describedArea)")
    }

    /// The watchdog lives only while the pen is in range: there is nothing to watch when
    /// nothing can go silent. A timer running all the time at 10 Hz would wake the process
    /// 864 000 times a day, including when the tablet is not even plugged in.
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, self.gate.inProximity else { return }
            guard Date().timeIntervalSince(self.lastReport) > Self.proximityTimeout else { return }
            self.leaveProximity()
        }
        timer.resume()
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// The tablet was unplugged — we must not leave a held button and a hanging proximity.
    func reset() {
        guard gate.inProximity else { return }
        leaveProximity()
    }

    // MARK: - Main path

    func handle(_ state: PenState) {
        guard let mapper, let curve else { return }
        lastReport = Date()

        let step = gate.report(inRange: state.inRange, now: lastReport)
        switch step {
        case .idle:
            return
        case .wait:
            scheduleExit()
            return
        case .enter, .stay:
            cancelExit()
        }

        let point = mapper.point(x: state.x, y: state.y)
        lastPoint = point

        if step == .enter {
            enterProximity(eraser: state.invert, at: point)
        }

        // A pen that lies still sends the same report a hundred times per
        // second. There is no reason to pass that on.
        if lastState == state { return }
        lastState = state

        emitPoint(state: state, at: point, pressure: curve.normalized(state.pressure))
    }

    /// The countdown any in-range report cancels. On a real lift no report comes,
    /// and the pen leaves the range `ProximityGate.grace` after the announcement — sooner
    /// than the silence timeout, which stays for the case where the stream stops
    /// without any announcement at all.
    private func scheduleExit() {
        guard exitWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.exitWork = nil
            // The pen may have come back while this was waiting in the queue.
            guard self.gate.hasLeft(by: Date()) else { return }
            self.leaveProximity()
        }
        exitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ProximityGate.grace, execute: work)
    }

    private func cancelExit() {
        exitWork?.cancel()
        exitWork = nil
    }

    // MARK: - Proximity

    private func enterProximity(eraser: Bool, at point: CGPoint) {
        proximityIsEraser = eraser
        startWatchdog()
        postProximity(entering: true, eraser: eraser, at: point)
        Log.debug("pen in range\(eraser ? " (eraser)" : "")")
    }

    private func leaveProximity() {
        cancelExit()
        if case .release(let button)? = buttons.releaseHeld() {
            // We get here when the range was left with the pen pressed down: the
            // cable was pulled out, or the silence timeout fired. `lastState` only
            // supplies the coordinates now; the button mask comes from `held`, and
            // nothing is held after a release.
            postMouse(
                type: upType(button), button: button, at: lastPoint,
                state: lastState ?? PenState(), pressure: 0, held: nil)
        }
        gate.left()
        stopWatchdog()
        lastState = nil
        postProximity(entering: false, eraser: proximityIsEraser, at: lastPoint)
        Log.debug("pen left the range")
    }

    /// Two events are sent, and each has its own addressee.
    ///
    /// Qt apps — Krita, Clip Studio — register the tablet only from a **real**
    /// event of type `kCGEventTabletProximity`: it reaches them as
    /// `NSEventTypeTabletProximity` and calls `tabletProximity:`. A mouse event
    /// with subtype 2 does not cause that call — it arrives as `mouseMoved`, and
    /// the tablet handler rejects it. Without that registration, Qt does not find
    /// the device by `deviceID` in the point events and silently treats them as a
    /// plain mouse: the cursor moves, clicks work, pressure is lost. This is
    /// exactly the symptom we saw.
    ///
    /// The mouse variant is kept for apps that look at the subtype of mouse
    /// events. There are only a few range changes per second, so the second
    /// event costs nothing.
    private func postProximity(entering: Bool, eraser: Bool, at point: CGPoint) {
        postProximityEvent(entering: entering, eraser: eraser, at: point, asTabletType: true)
        postProximityEvent(entering: entering, eraser: eraser, at: point, asTabletType: false)
    }

    private func postProximityEvent(
        entering: Bool, eraser: Bool,
        at point: CGPoint, asTabletType: Bool
    ) {
        // CoreGraphics has no separate constructor for the `tabletProximity` type,
        // so the event is made as a mouse event and the type is changed after — this
        // way it keeps a correct source, timestamp and position.
        guard
            let event = CGEvent(
                mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)
        else { return }
        if asTabletType { event.type = .tabletProximity }
        event.setIntegerValueField(
            .mouseEventSubtype,
            value: Int64(CGEventMouseSubtype.tabletProximity.rawValue))
        event.setIntegerValueField(.tabletProximityEventVendorID, value: vendorID)
        event.setIntegerValueField(.tabletProximityEventTabletID, value: tabletID)
        event.setIntegerValueField(.tabletProximityEventPointerID, value: 0)
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)
        event.setIntegerValueField(.tabletProximityEventVendorPointerType, value: 0)
        event.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: 0)
        event.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: penSerial)
        event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: Self.capabilityMask)
        event.setIntegerValueField(
            .tabletProximityEventPointerType,
            value: eraser ? Self.pointerTypeEraser : Self.pointerTypePen)
        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Points

    private func emitPoint(state: PenState, at point: CGPoint, pressure: Double) {
        for action in buttons.update(state, buttons: penButtons) {
            switch action {
            case .move:
                postMouse(
                    type: .mouseMoved, button: .left, at: point, state: state,
                    pressure: pressure, held: nil)
            case .press(let button):
                _ = clicks.press(
                    at: point, button: button, interval: NSEvent.doubleClickInterval)
                postMouse(
                    type: downType(button), button: button, at: point, state: state,
                    pressure: pressure, held: button)
            case .drag(let button):
                postMouse(
                    type: draggedType(button), button: button, at: point, state: state,
                    pressure: pressure, held: button)
            case .release(let button):
                // The button is going up, so nothing is held any more.
                postMouse(
                    type: upType(button), button: button, at: point, state: state,
                    pressure: 0, held: nil)
            }
        }
    }

    private func postMouse(
        type: CGEventType, button: CGMouseButton,
        at point: CGPoint, state: PenState, pressure: Double, held: CGMouseButton?
    ) {
        guard
            let event = CGEvent(
                mouseEventSource: source, mouseType: type,
                mouseCursorPosition: point, mouseButton: button)
        else { return }
        event.setIntegerValueField(
            .mouseEventSubtype,
            value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        event.setIntegerValueField(.mouseEventClickState, value: clicks.count)
        event.setDoubleValueField(.mouseEventPressure, value: pressure)

        event.setIntegerValueField(.tabletEventPointX, value: Int64(state.x))
        event.setIntegerValueField(.tabletEventPointY, value: Int64(state.y))
        event.setIntegerValueField(.tabletEventPointZ, value: 0)
        event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        event.setIntegerValueField(
            .tabletEventPointButtons, value: tabletButtonMask(for: held))
        event.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
        event.post(tap: .cghidEventTap)
    }

    private func downType(_ button: CGMouseButton) -> CGEventType {
        switch button {
        case .right: return .rightMouseDown
        case .left: return .leftMouseDown
        default: return .otherMouseDown
        }
    }

    private func upType(_ button: CGMouseButton) -> CGEventType {
        switch button {
        case .right: return .rightMouseUp
        case .left: return .leftMouseUp
        default: return .otherMouseUp
        }
    }

    private func draggedType(_ button: CGMouseButton) -> CGEventType {
        switch button {
        case .right: return .rightMouseDragged
        case .left: return .leftMouseDragged
        default: return .otherMouseDragged
        }
    }
}
