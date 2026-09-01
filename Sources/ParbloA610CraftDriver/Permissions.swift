import CUCLogic
import Foundation
import ParbloA610Core

/// macOS asks a driver for two different permissions, and each program gets
/// them on its own.
///
/// A silent failure here plays out like this: the driver would
/// seize the tablet, take it away from the system event service and throw away
/// everything it produces, while the log would still look fine. Before the
/// driver started, the tablet at least worked as a crude mouse.
///
/// Both are checked at once, in one pass: otherwise the user would have to turn
/// the switches on in two rounds, restarting the driver in between.
enum Permissions {
    private static let granted: Int32 = 0
    private static let unknown: Int32 = 2

    private struct Requirement {
        let pane: String
        let why: String
        let check: () -> Int32
        let request: () -> Int32
    }

    private static let inputMonitoring = Requirement(
        pane: "Input Monitoring",
        why: "read the tablet and seize its interface",
        check: uclogic_check_input_monitoring,
        request: uclogic_request_input_monitoring)

    /// Measured: with `IOHIDCheckAccess(PostEvent) = denied` a posted event does
    /// not move the cursor — and no error is returned for it.
    private static let postEvent = Requirement(
        pane: "Accessibility",
        why: "so that tablet events are really sent and do not disappear",
        check: uclogic_check_post_event,
        request: uclogic_request_post_event)

    /// `posting: false` is the `--dump` mode: the driver sends nothing, so it
    /// does not need the permission to post events either.
    static func ensure(posting: Bool) -> Bool {
        let required = posting ? [inputMonitoring, postEvent] : [inputMonitoring]
        let missing = required.filter { !satisfy($0) }
        guard !missing.isEmpty else { return true }

        let binary = CommandLine.arguments.first ?? "driver binary"
        let list =
            missing
            .map { "  • \($0.pane)\n      — \($0.why)" }
            .joined(separator: "\n")
        Log.error(
            """
            permissions are not granted.

            System Settings → Privacy & Security →
            \(list)

            In each of these sections add:
                \(binary)

            If the system showed a dialog — accept it, it leads straight to the right
            section. If not, add it by hand with the "+" button: in the file dialog
            press ⇧⌘G and paste the whole path.

            Each program gets the permission on its own, it is not inherited: a run
            from Terminal needs the switches on Terminal. After turning them on:
                launchctl kickstart -k gui/$(id -u)/com.rey.parblo-a610-craft-driver
            """)
        return false
    }

    private static func satisfy(_ requirement: Requirement) -> Bool {
        if requirement.check() == granted { return true }
        // "Unknown" means the system has not asked yet. So we ask — that is what
        // shows the user a dialog with a link to the right settings section.
        if requirement.check() == unknown {
            _ = requirement.request()
        }
        return requirement.check() == granted
    }
}
