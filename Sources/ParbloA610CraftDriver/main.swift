import AppKit
import CoreGraphics
import Foundation
import ParbloA610Core

// Device check. At least three different tablets share this VID/PID, so a
// connection is also checked against firmware string descriptor #201.
let vendorID = 0x5543
let productID = 0x0081
let firmware = "F401-HK708-STD"

let arguments = Set(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(
        """
        parblo-a610-craft-driver — Parblo A610 driver for macOS

          --verbose   detailed log: proximity, pen entering and leaving
          --dump      only print the parsed pen stream, do not send events
          --help      this message

        Config: \(ConfigStore.url.path)
        """)
    exit(0)
}
Log.verbose = arguments.contains("--verbose")

// Under launchd there is no terminal, and output has to go to a file that the
// driver watches itself. Started by hand — it prints to the screen.
if isatty(STDOUT_FILENO) == 0 {
    Log.start(
        file: ConfigStore.url.deletingLastPathComponent()
            .appendingPathComponent("parblo-a610-craft-driver.log"))
}
let dumpOnly = arguments.contains("--dump")

// Both permissions are checked before anything else. The posting check cannot
// be skipped: without it the driver takes the tablet away from the system and
// throws away everything it produces, and says nothing about it.
guard Permissions.ensure(posting: !dumpOnly) else { exit(1) }

let store = ConfigStore()
store.load()

let emitter = TabletEventEmitter(vendorID: vendorID, productID: productID)
let watcher = DeviceWatcher(vendorID: vendorID, productID: productID, expectedFirmware: firmware)

// Pen parameters are read off the device, so the mapper and the curve are built
// again on every connection and on every config change.
var currentParams: TabletParams?

/// The mapper holds the display bounds, read once, and the curve holds the pen
/// parameters. Everything that can move them goes through this function.
func applyConfiguration() {
    guard let params = currentParams else { return }
    emitter.configure(params: params, config: store.config)
}

watcher.onAttach = { params in
    currentParams = params
    applyConfiguration()
    if dumpOnly { Log.info("Mode --dump: events are not sent.") }
}

watcher.onDetach = {
    currentParams = nil
    emitter.reset()
}

watcher.onReport = { state in
    if dumpOnly {
        Log.info(
            String(
                format: "X=%5d Y=%5d P=%4d  %@%@%@%@%@",
                state.x, state.y, state.pressure,
                state.tipSwitch ? "touch " : "",
                state.barrel1 ? "lower " : "",
                state.barrel2 ? "upper " : "",
                state.invert ? "inverted " : "",
                state.inRange ? "in-range" : "out-of-range"))
        return
    }
    emitter.handle(state)
}

store.onChange = { _ in applyConfiguration() }

// A resolution change, a screen rotation, plugging in a monitor or a dock move
// the display bounds. Without this the pen would stop reaching the edge: the
// mapper would keep stretching the tablet onto a rectangle that is gone. The
// begin flag arrives before the rebuild, when the new bounds are not ready yet.
CGDisplayRegisterReconfigurationCallback(
    { _, flags, _ in
        guard !flags.contains(.beginConfigurationFlag) else { return }
        DispatchQueue.main.async { applyConfiguration() }
    }, nil)

// Whether full mode survives sleep stays untested. The failure mode is a quiet
// fall back to interface 1. Reading string descriptor 100 again is idempotent and
// costs one control transfer, so we always do it.
let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
) { _ in
    watcher.reinitialize()
}

var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGINT, SIGTERM] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        emitter.reset()
        Log.info("Stopped.")
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

watcher.start()
CFRunLoopRun()
_ = wakeObserver
