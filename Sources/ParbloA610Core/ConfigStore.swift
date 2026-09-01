import Foundation

/// Reads the config and watches the file. Changes arrive in `onChange`
/// on the main queue.
package final class ConfigStore {
    package static let url = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/parblo-a610-craft-driver/config.json")

    package private(set) var config = Config()
    package var onChange: ((Config) -> Void)?

    /// The file this store works with. The driver uses the shared path; the
    /// settings app and the tests pass their own.
    private let fileURL: URL

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var reportedWatchFailure = false

    package init(url: URL = ConfigStore.url) {
        fileURL = url
    }

    package func load() {
        createDefaultIfMissing()
        config = read() ?? Config()
        watch()
    }

    private func read() -> Config? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            Log.error("config.json does not parse as JSON — keeping the previous settings.")
            return nil
        }
        return Config(json: json)
    }

    private func createDefaultIfMissing() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        do {
            try fm.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Config.defaultJSON.write(to: fileURL, atomically: true, encoding: .utf8)
            Log.info("Created the default config: \(fileURL.path)")
        } catch {
            Log.error("Could not create the config: \(error.localizedDescription)")
        }
    }

    /// Editors usually replace the file, so the watch is set up again on every
    /// rename or delete.
    private func watch() {
        source?.cancel()
        source = nil

        descriptor = open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The file may have been deleted for good — for example to get the default
            // settings back. Simply returning here would kill the watch until the
            // process ends, and do it silently.
            if !reportedWatchFailure {
                reportedWatchFailure = true
                Log.error("config.json does not open — creating it again and keeping the watch.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.createDefaultIfMissing()
                self.watch()
            }
            return
        }
        reportedWatchFailure = false

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.rename) || events.contains(.delete) {
                // The file was replaced — re-attach, giving the write time to finish.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.reload(rewatch: true) }
            } else {
                self.reload(rewatch: false)
            }
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        source.resume()
        self.source = source
    }

    private func reload(rewatch: Bool) {
        if rewatch {
            createDefaultIfMissing()
            watch()
        }
        guard let fresh = read(), fresh != config else { return }
        config = fresh
        Log.info("Config re-read.")
        onChange?(fresh)
    }
}
