import Foundation
import Testing

@testable import ParbloA610Core
@testable import ParbloA610Settings

@Suite("Settings app")
struct SettingsAppTests {

    /// The status badge in the window depends on this parsing. A bug here would
    /// show "running" while the driver is down, and this is exactly the kind of
    /// mismatch we hit most often today.
    @Test("driver state is read from the launchctl output")
    func driverStatusParsing() {
        #expect(DriverStatus.parse("\tstate = running\n\tpid = 123") == .running)
        #expect(DriverStatus.parse(nil) == .notInstalled)
        #expect(
            DriverStatus.parse("Could not find service \"com.rey.x\" in domain for uid: 501")
                == .notInstalled)
        #expect(
            DriverStatus.parse("\tstate = not running\n\tlast exit code = 1")
                == .stopped(lastExitCode: 1))
        #expect(
            DriverStatus.parse("\tstate = not running\n\tlast exit code = 0")
                == .stopped(lastExitCode: 0))
        #expect(DriverStatus.parse("\tstate = not running") == .stopped(lastExitCode: nil))
    }

    @Test("a permission failure is explained in words")
    func exitCodeOne() {
        // `title` is what the settings window shows, so the wording is part of
        // the contract: exit code 1 has to name the permissions.
        #expect(DriverStatus.State.stopped(lastExitCode: 1).title.contains("permissions"))
        #expect(DriverStatus.State.running.isHealthy)
        #expect(!DriverStatus.State.stopped(lastExitCode: nil).isHealthy)
    }

    /// The config holds `main` or the number in the list of active displays. An
    /// off-by-one error would send the output to the wrong screen.
    @Test("a display turns into a config value")
    func displayConfigValue() {
        let main = DisplayOption(id: 1, index: 0, bounds: .zero, isMain: true)
        let second = DisplayOption(id: 2, index: 1, bounds: .zero, isMain: false)
        #expect(main.configValue == "main")
        #expect(second.configValue == "1")
        #expect(second.title.contains("Display 2"))
    }

    /// The app and the driver are linked only by the file. If a write does not
    /// get through, settings would be lost without any message.
    @Test("what is read from the file and written back match")
    func modelReadsAndWritesFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parblo-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")

        var written = Config()
        written.orientation = 90
        written.pressure.gamma = 1.6
        try written.save(to: file)

        let model = AppModel(configURL: file)
        #expect(model.config.orientation == 90)
        #expect(model.config.pressure.gamma == 1.6)
    }

    /// The window keeps its own copy of the settings and writes the whole file
    /// at once. An edit made outside while the window was open used to be
    /// overwritten by that copy on the next slider move.
    @Test("an outside edit is taken in and is not written back over")
    func adoptsOutsideEdit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parblo-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        try Config().save(to: file)

        let model = AppModel(configURL: file)
        model.config.orientation = 90

        var outside = Config()
        outside.orientation = 180
        outside.pressure.gamma = 1.2
        model.adopt(outside)

        #expect(model.config == outside)
        #expect(model.savedAt == nil, "an adopted value must not look saved")
    }

    @Test("a missing file gives defaults")
    func missingFileFallsBackToDefaults() {
        let missing = URL(fileURLWithPath: "/nonexistent/parblo/config.json")
        #expect(AppModel(configURL: missing).config == Config())
    }
}
