import Foundation
import Testing

@testable import ParbloA610Core

/// Serialized: `Log` is shared state of the process.
@Suite("Log rotation", .serialized)
struct LogTests {

    /// Nobody else rotates this file, so the code that writes it must do it.
    /// The driver runs for months, so there has to be a size limit.
    @Test("on overflow a new file starts and the previous one is kept")
    func rotates() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parblo-log-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("driver.log")
        let previous = file.appendingPathExtension("1")
        defer { try? FileManager.default.removeItem(at: dir) }

        let saved = Log.maxBytes
        defer { Log.maxBytes = saved }
        Log.maxBytes = 400

        Log.start(file: file)
        for i in 1...40 {
            Log.info("line number \(i), long enough to reach the limit quickly")
        }
        Log.info("last line")

        #expect(
            FileManager.default.fileExists(atPath: previous.path), "the previous file must remain")

        let current = try String(contentsOf: file, encoding: .utf8)
        #expect(current.contains("last line"), "writing continues after rotation")
        #expect(current.utf8.count <= Log.maxBytes, "the limit is not exceeded")
    }

    /// Rotation used to reopen the file and check the size again, so a rename
    /// that could not happen sent it round for another try — every line, until
    /// the stack ran out. A driver that dies on its own log restarts, fills the
    /// log again and dies again.
    @Test("rotation that cannot rename the file keeps writing")
    func rotationSurvivesAReadOnlyDirectory() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parblo-log-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("driver.log")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? fm.removeItem(at: dir)
        }

        let saved = Log.maxBytes
        defer { Log.maxBytes = saved }
        Log.maxBytes = 400

        Log.start(file: file)
        Log.info("first line")
        // No rename and no delete can happen in a directory nobody may write to.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        for i in 1...40 {
            Log.info("line number \(i), long enough to reach the limit quickly")
        }
        Log.info("last line")

        let current = try String(contentsOf: file, encoding: .utf8)
        #expect(current.contains("last line"), "writing continues")
        #expect(current.utf8.count <= Log.maxBytes, "the file stays inside the limit")
    }
}
