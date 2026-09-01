import CoreGraphics
import ParbloA610Core

/// Bits of the `kCGTabletEventPointButtons` field.
///
/// `IOLLEvent.h` is explicit: "The buttons field adopts the following
/// convention: bit 0 Left Mouse Button, bit 1 Right Mouse Button, bit 2 Middle
/// Mouse Button". The `NX_TABLET_BUTTON_PENTIP`, `PENLOWERSIDE` and
/// `PENUPPERSIDE` names are only aliases for the same bits under the default
/// mapping, where the tip acts as the left button and the lower barrel as the
/// right one.
///
/// So the mask follows the button we really press. Built from the raw pen state
/// it made the event contradict itself: with `barrel1: leftClick` we sent a left
/// button down while the mask said the right button was held, and with
/// `barrel1: none` we sent no button at all and still claimed one.
func tabletButtonMask(for button: CGMouseButton?) -> Int64 {
    switch button {
    case .left: return 0x0001
    case .right: return 0x0002
    case .center: return 0x0004
    default: return 0
    }
}

/// The pen input that holds a mouse button down.
enum ButtonSource: Equatable {
    case tip
    case barrel1
    case barrel2

    func isPressed(in state: PenState) -> Bool {
        switch self {
        case .tip: return state.tipSwitch
        case .barrel1: return state.barrel1
        case .barrel2: return state.barrel2
        }
    }
}

/// What to do with the mouse button on the next report.
enum ButtonAction: Equatable {
    case move
    case press(CGMouseButton)
    case drag(CGMouseButton)
    case release(CGMouseButton)
}

/// Mouse button state, kept apart from sending events.
///
/// It is separate so that it can be tested: this is where a bug lived that the eye does
/// not catch. The button was released only when **all** inputs were released at once, and
/// the barrel button ranks above the pen tip in `desired`. Because of that, a pen lifted
/// off the tablet with the barrel button held left the left button pressed — and the
/// stroke kept on drawing while the pen moved through the air.
///
/// The right rule: release when the input that **opened** this button is released, not
/// when everything is released.
struct ButtonTracker {
    private struct Held {
        let button: CGMouseButton
        let source: ButtonSource
    }

    private var held: Held?

    var heldButton: CGMouseButton? { held?.button }

    /// One report gives at most two actions: the release of the previous button and the
    /// press of the next one — when one input replaces another.
    mutating func update(_ state: PenState, buttons: Config.PenButtons) -> [ButtonAction] {
        var actions: [ButtonAction] = []

        if let current = held, !current.source.isPressed(in: state) {
            actions.append(.release(current.button))
            held = nil
        }

        if let current = held {
            // We do not change the button in the middle of a stroke: a barrel button
            // pressed along the way must not turn a left stroke into a right one.
            actions.append(.drag(current.button))
            return actions
        }

        guard let next = Self.desired(state, buttons) else {
            actions.append(.move)
            return actions
        }
        held = Held(button: next.0, source: next.1)
        actions.append(.press(next.0))
        return actions
    }

    /// The pen left the range or the device is gone — the button must not stay held.
    mutating func releaseHeld() -> ButtonAction? {
        guard let current = held else { return nil }
        held = nil
        return .release(current.button)
    }

    /// The barrel button wins over the pen tip: hold it and you draw with its button.
    private static func desired(
        _ state: PenState, _ buttons: Config.PenButtons
    ) -> (CGMouseButton, ButtonSource)? {
        if state.barrel1, let button = buttons.barrel1.mouseButton { return (button, .barrel1) }
        if state.barrel2, let button = buttons.barrel2.mouseButton { return (button, .barrel2) }
        return state.tipSwitch ? (.left, .tip) : nil
    }
}
