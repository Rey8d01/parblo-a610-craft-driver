import Foundation

/// Writes to the file itself.
///
/// A file that nobody rotates is the job of whoever writes to it — macOS does
/// not do this by itself. While `launchd` redirected the output, it held the
/// descriptor, and an overgrown file could only be trimmed from outside the
/// process.
///
/// `main` decides whether to write to a file or to the terminal: a driver started
/// by hand has to print on screen, or `--dump` would be useless.
package enum Log {
    package static var verbose = false

    /// Limit for one file; the previous one is kept next to it with the `.1` suffix.
    /// One megabyte is enough for about three years: in normal work it writes about
    /// half a kilobyte a day — one line per connect, wake and stop.
    package static var maxBytes = 1 << 20

    private static var url: URL?
    private static var handle: FileHandle?
    private static var size = 0
    /// Set when rotation could not bring the file back under the limit. Without
    /// it every next line would try to rotate again, and the same failure would
    /// repeat for as long as the process lives.
    private static var rotationBroken = false

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Send the output to a file. Without this call everything goes to the terminal.
    package static func start(file url: URL) {
        self.url = url
        rotationBroken = false
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        openFile()
        if size >= maxBytes { rotate() }
    }

    package static func info(_ message: String) {
        emit(message)
    }

    package static func debug(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        emit(message())
    }

    package static func error(_ message: String) {
        emit("ERROR: " + message, toStandardError: true)
    }

    // MARK: - Writing

    private static func emit(_ message: String, toStandardError: Bool = false) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        let data = Data(line.utf8)

        guard url != nil else {
            if toStandardError {
                FileHandle.standardError.write(data)
            } else {
                print(line, terminator: "")
                fflush(stdout)
            }
            return
        }

        // The check runs before the write. That keeps the limit intact and leaves
        // the newest line in the current file, where a check after the write would
        // send it into the rotated one.
        if !rotationBroken, size + data.count > maxBytes { rotate() }
        guard let handle else { return }
        try? handle.write(contentsOf: data)
        size += data.count
    }

    private static func openFile() {
        guard let url else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    /// Rotation never calls back into the size check. Renaming can fail — a read
    /// only directory, a `.1` held by somebody else — and the file would then stay
    /// over the limit; a check that rotates again on the way back would recurse
    /// until the stack ran out and take the driver down with it.
    private static func rotate() {
        guard let url else { return }
        try? handle?.close()
        handle = nil

        let previous = url.appendingPathExtension("1")
        let fm = FileManager.default
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: url, to: previous)

        openFile()
        guard size >= maxBytes else { return }

        // The rename did not happen, so the old lines are still here. The
        // descriptor is ours: cutting the file to zero needs no rights on the
        // directory. `seekToEnd` then reports the real size — zero if the cut
        // worked, the old size if it did not.
        try? handle?.truncate(atOffset: 0)
        size = Int((try? handle?.seekToEnd()) ?? 0)
        guard size >= maxBytes else { return }

        rotationBroken = true
        FileHandle.standardError.write(
            Data("ERROR: log rotation failed, \(url.path) will keep growing\n".utf8))
    }
}
