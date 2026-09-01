import CUCLogic
import Foundation
import IOKit
import IOKit.hid
import ParbloA610Core

private let reportBufferSize = 64

/// Watches the tablet appear and disappear, switches it into full mode
/// and gives out the parsed pen stream.
///
/// The pen interface (`0x0D`/`0x02`) is opened with `kIOHIDOptionsTypeSeizeDevice`,
/// so `IOHIDManagerOpen` is not called on purpose: it would open the devices
/// itself, the normal way, and the seize would mean nothing.
///
/// The compatibility interface (`0x01`/`0x02`) is opened **without** a seize, and only
/// to watch it — see `watchForModeLoss`.
final class DeviceWatcher {
    /// Pause before the next connection attempt.
    private static let retryDelay: TimeInterval = 5
    /// How many extra tries to give the firmware string after the first read
    /// fails, before going on without it. At `retryDelay` each, that is about
    /// 15 seconds.
    private static let firmwareRetries = 3
    /// No more than one mode recovery in this time.
    private static let recoveryInterval: TimeInterval = 2

    private let vendorID: Int
    private let productID: Int
    private let expectedFirmware: String

    var onAttach: ((TabletParams) -> Void)?
    var onDetach: (() -> Void)?
    var onReport: ((PenState) -> Void)?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var compatDevice: IOHIDDevice?

    /// A device we failed to connect to, and will try again.
    private var pendingRetry: IOHIDDevice?
    private var retryScheduled = false
    /// So we do not repeat the error message every five seconds.
    private var failureReported = false
    /// The same three for the compatibility interface, kept apart: the two
    /// interfaces open on their own, and one failing must not cancel the other's
    /// retry.
    private var pendingCompat: IOHIDDevice?
    private var compatRetryScheduled = false
    private var compatFailureReported = false
    /// How many times in a row the firmware string could not be read.
    private var firmwareReadFailures = 0
    private var lastRecovery = Date.distantPast

    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)
    private let compatBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportBufferSize)

    init(vendorID: Int, productID: Int, expectedFirmware: String) {
        self.vendorID = vendorID
        self.productID = productID
        self.expectedFirmware = expectedFirmware
    }

    deinit {
        buffer.deallocate()
        compatBuffer.deallocate()
    }

    // MARK: - Start

    func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        // Interface 2 (keyboard) is the express keys. They work on their own, so we
        // do not need them here; and opening someone else's keyboard stream makes
        // even less sense.
        let matches = [Self.penUsagePage, Self.compatUsagePage].map { page in
            [
                kIOHIDVendorIDKey: vendorID,
                kIOHIDProductIDKey: productID,
                kIOHIDPrimaryUsagePageKey: page,
                kIOHIDPrimaryUsageKey: 0x02,
            ] as [String: Any]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { context, _, _, device in
                guard let context else { return }
                Unmanaged<DeviceWatcher>.fromOpaque(context).takeUnretainedValue().matched(device)
            }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { context, _, _, device in
                guard let context else { return }
                Unmanaged<DeviceWatcher>.fromOpaque(context).takeUnretainedValue().removed(device)
            }, context)

        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue)
        Log.info("Waiting for tablet \(hex(vendorID)):\(hex(productID))…")
    }

    /// Switch to full mode again — after wake from sleep.
    func reinitialize() {
        guard let device else { return }
        Log.info(
            enterFullMode(locationID: locationID(of: device)) != nil
                ? "Full mode set up again after wake."
                : "Could not set up full mode again after wake.")
    }

    // MARK: - Sorting the interfaces

    private static let penUsagePage = 0x0D
    private static let compatUsagePage = 0x01

    private func matched(_ device: IOHIDDevice) {
        switch usagePage(of: device) {
        case Self.penUsagePage: attach(device)
        case Self.compatUsagePage: watchForModeLoss(device)
        default: break
        }
    }

    private func removed(_ device: IOHIDDevice) {
        if pendingRetry === device {
            pendingRetry = nil
            // The counter belongs to that device. Left standing, the next tablet
            // would inherit it and get fewer attempts than it should.
            firmwareReadFailures = 0
        }
        if pendingCompat === device {
            pendingCompat = nil
            compatFailureReported = false
        }
        if compatDevice === device { compatDevice = nil }
        guard self.device === device else { return }
        IOHIDDeviceUnscheduleFromRunLoop(
            device, CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue)
        self.device = nil
        failureReported = false
        firmwareReadFailures = 0
        Log.info("Tablet disconnected.")
        onDetach?()
    }

    private func usagePage(of device: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? 0
    }

    // MARK: - Opening the pen interface

    private func attach(_ device: IOHIDDevice) {
        guard self.device == nil else { return }
        let location = locationID(of: device)

        switch identify(locationID: location) {
        case .confirmed:
            // The location id is logged too: with two tablets of the same model
            // it is the only thing that tells them apart in the log.
            Log.info(
                "Firmware checked: \(expectedFirmware), device 0x"
                    + String(format: "%08X", location))
            firmwareReadFailures = 0

        case .foreign(let firmware):
            // Somebody else's tablet. Retrying will not change the answer, and
            // touching it would switch its mode and take its interface away.
            Log.error(
                "Firmware is '\(firmware)', expected '\(expectedFirmware)'. "
                    + "This is a different tablet with the same VID/PID — leaving it alone.")
            return

        case .unreadable(let code):
            // A failed read is not proof of anything. Retry a few times first:
            // giving up at once would leave our own tablet dead after a passing
            // glitch, which is the far more common case.
            firmwareReadFailures += 1
            if firmwareReadFailures <= Self.firmwareRetries {
                if firmwareReadFailures == 1 {
                    Log.info(
                        "Firmware string descriptor 201 not read (code \(code)) — will retry.")
                }
                pendingRetry = device
                scheduleRetry()
                return
            }
            // Still unreadable. Going on is the lesser evil: two tablets with
            // this VID/PID on one machine are rare, a dead tablet is not.
            Log.error(
                "Firmware string descriptor 201 still not read after "
                    + "\(firmwareReadFailures) tries (code \(code)). Going on without the "
                    + "check — if this is not an A610, unplug it.")
        }

        if openPen(device, locationID: location) {
            pendingRetry = nil
            failureReported = false
        } else {
            // The connection can fail for a short-lived reason: another process
            // still holds the device, or the port is not awake yet. Without a
            // retry the tablet would stay dead until it is replugged — and it
            // would stay quiet about it.
            pendingRetry = device
            scheduleRetry()
        }
    }

    private func openPen(_ device: IOHIDDevice, locationID: UInt32) -> Bool {
        // Reading string descriptor 100 moves the tablet from compatibility mode to
        // full mode, and also gives us the pen parameters. No need to hardcode them.
        guard let params = enterFullMode(locationID: locationID) else {
            report("Init failed. The tablet stayed in compatibility mode.")
            return false
        }

        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard opened == kIOReturnSuccess else {
            report(
                "Could not seize the pen interface (0x\(String(opened, radix: 16))). "
                    + (opened == kIOReturnNotPermitted
                        ? "It looks like Input Monitoring is not granted."
                        : "The device is busy in another process."))
            return false
        }

        self.device = device
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, reportBufferSize,
            { context, _, _, _, reportID, report, length in
                guard let context, length > 0 else { return }
                let watcher = Unmanaged<DeviceWatcher>.fromOpaque(context).takeUnretainedValue()
                let bytes = UnsafeBufferPointer(start: report, count: Int(length))
                guard let state = ReportParser.parse(reportID: reportID, buffer: bytes) else {
                    return
                }
                watcher.onReport?(state)
            }, context)
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue)

        let inches = { (units: Int) in Double(units) * 1000.0 / Double(params.resolution) / 1000.0 }
        Log.info(
            "Tablet connected and seized. "
                + "X 0..\(params.xMax), Y 0..\(params.yMax), pressure 0..\(params.pressureMax), "
                + "\(params.resolution) LPI "
                + String(format: "(%.1f″ × %.1f″)", inches(params.xMax), inches(params.yMax)))
        onAttach?(params)
        return true
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            guard self.device == nil, let waiting = self.pendingRetry else { return }
            self.attach(waiting)
        }
    }

    private func scheduleCompatRetry() {
        guard !compatRetryScheduled else { return }
        compatRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
            guard let self else { return }
            self.compatRetryScheduled = false
            guard self.compatDevice == nil, let waiting = self.pendingCompat else { return }
            self.watchForModeLoss(waiting)
        }
    }

    /// We report the same failure only once: the retry runs every five seconds,
    /// and the log must not turn into a stream of identical lines.
    private func report(_ message: String) {
        guard !failureReported else { return }
        failureReported = true
        Log.error(message + " Will try again in \(Int(Self.retryDelay)) s.")
    }

    // MARK: - Loss of full mode

    /// The tablet can fall back to compatibility mode without disconnecting: a bus
    /// glitch, a power drop, another program that touched the device. Then the pen
    /// moves to the compatibility interface, while we sit seized on a pen interface
    /// that has gone quiet — quiet and forever, because we only re-initialize on an
    /// attach event, and there was no attach event.
    ///
    /// In full mode the compatibility interface sends nothing, so any report from it
    /// means exactly one thing: the mode is lost. We listen without a seize — the
    /// system owns that interface anyway, so we take nothing away from it.
    private func watchForModeLoss(_ device: IOHIDDevice) {
        guard compatDevice == nil else { return }
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            // The reasons are the short lived ones we already retry on the pen
            // interface: another process still holds the device, or the port is
            // not awake yet. Giving up here would switch the mode watch off until
            // the tablet is replugged, and say so only once.
            if !compatFailureReported {
                compatFailureReported = true
                Log.error(
                    "Could not open the compatibility interface "
                        + "(0x\(String(opened, radix: 16))) — a lost mode would go unnoticed.")
            }
            pendingCompat = device
            scheduleCompatRetry()
            return
        }
        pendingCompat = nil
        compatFailureReported = false
        compatDevice = device

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, compatBuffer, reportBufferSize,
            { context, _, _, _, _, _, length in
                guard let context, length > 0 else { return }
                Unmanaged<DeviceWatcher>.fromOpaque(context).takeUnretainedValue().recoverFullMode()
            }, context)
        IOHIDDeviceScheduleWithRunLoop(
            device, CFRunLoopGetCurrent(),
            CFRunLoopMode.defaultMode.rawValue)
    }

    private func recoverFullMode() {
        guard let device else { return }
        let now = Date()
        guard now.timeIntervalSince(lastRecovery) > Self.recoveryInterval else { return }
        lastRecovery = now

        Log.info("Pen showed up on the compatibility interface — the tablet lost full mode.")
        Log.info(
            enterFullMode(locationID: locationID(of: device)) != nil
                ? "Full mode restored."
                : "Could not restore full mode.")
    }

    // MARK: - Shared

    /// Reading string descriptor 100 is the only way to bring the tablet back to
    /// full mode. The request is idempotent: nothing is written to the device.
    private func enterFullMode(locationID: UInt32) -> TabletParams? {
        var raw = uclogic_params_t()
        guard uclogic_init(UInt16(vendorID), UInt16(productID), locationID, &raw) == UCLOGIC_OK
        else {
            return nil
        }
        return TabletParams(
            xMax: Int(raw.x_max), yMax: Int(raw.y_max),
            pressureMax: Int(raw.pressure_max), resolution: Int(raw.resolution))
    }

    /// What the firmware string told us about the device.
    ///
    /// Three states. A read that fails and a tablet that answers with the wrong
    /// name call for opposite handling: the first is usually a passing glitch on
    /// our own tablet, the second is somebody else's device that we must leave
    /// alone. One state for both meant either seizing a stranger's tablet or
    /// giving up on our own.
    private enum Identity {
        case confirmed
        case foreign(String)
        case unreadable(Int32)
    }

    /// At least three different tablets share `0x5543:0x0081`, so one VID/PID is not
    /// enough. String descriptor 201 on the A610 is `F401-HK708-STD`.
    private func identify(locationID: UInt32) -> Identity {
        var name = [CChar](repeating: 0, count: 64)
        let n = uclogic_read_string(
            UInt16(vendorID), UInt16(productID), locationID, 201, &name, 64)
        guard n > 0 else { return .unreadable(n) }
        let firmware = String(cString: name)
        return firmware == expectedFirmware ? .confirmed : .foreign(firmware)
    }

    /// The location id ties every request to one physical tablet. Without it a
    /// second device with the same VID/PID could be read and switched into full
    /// mode while we seize the interface of the first one.
    private func locationID(of device: IOHIDDevice) -> UInt32 {
        let value = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString)
        if let id = value as? UInt32 { return id }
        if let id = value as? Int { return UInt32(truncatingIfNeeded: id) }

        // Zero tells the C shim to match by VID/PID alone — the very behaviour the
        // location id was added to replace. A USB device should always have this
        // property, so a silent fallback here would hide a real problem.
        Log.error(
            "The HID device has no LocationID. Falling back to VID/PID only: with two "
                + "tablets of this model the wrong one could be read or switched.")
        return 0
    }

    private func hex(_ value: Int) -> String { "0x" + String(format: "%04X", value) }
}
