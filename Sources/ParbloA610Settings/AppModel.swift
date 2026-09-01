import AppKit
import Combine
import CoreGraphics
import ParbloA610Core

/// One display in the picker list.
struct DisplayOption: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let index: Int
    let bounds: CGRect
    let isMain: Bool

    /// Value for the config: `main`, or the index in the list of active displays.
    var configValue: String { isMain ? "main" : String(index) }

    var title: String {
        let size = "\(Int(bounds.width))×\(Int(bounds.height))"
        return isMain ? "Main · \(size)" : "Display \(index + 1) · \(size)"
    }
}

/// State of the settings window.
///
/// It writes `config.json` and stops there: the driver watches the file itself
/// and re-reads it on the fly. There is no other channel between them.
final class AppModel: ObservableObject {
    @Published var config: Config {
        didSet { if !isAdopting { scheduleSave() } }
    }
    @Published private(set) var savedAt: Date?
    @Published private(set) var saveError: String?

    /// Tablet parameters. The driver reads them from the device; here they are
    /// only needed to draw the active area in the right units.
    let tablet = TabletParams.a610

    private var saveWork: DispatchWorkItem?
    private let configURL: URL
    /// The same store the driver uses: it reads the file and watches it.
    private let store: ConfigStore
    /// True while an outside change is being taken in, so `didSet` does not
    /// write that same value straight back to the file.
    private var isAdopting = false

    /// The path is a parameter only for the tests: otherwise they would write
    /// to the owner's real config.
    init(configURL: URL = ConfigStore.url) {
        self.configURL = configURL
        store = ConfigStore(url: configURL)
        store.load()
        config = store.config
        store.onChange = { [weak self] fresh in self?.adopt(fresh) }
    }

    /// The file can change while the window is open: edited by hand, replaced by
    /// a backup, reset by a second copy of this app. Reading it only at startup
    /// meant the next slider move wrote the whole stale copy back over it.
    func adopt(_ fresh: Config) {
        guard fresh != config else { return }
        // A save waiting in the queue holds the value we are replacing. Letting
        // it run would put the old settings back into the file half a second
        // after the owner's own edit landed there.
        saveWork?.cancel()
        savedAt = nil
        isAdopting = true
        config = fresh
        isAdopting = false
    }

    var displays: [DisplayOption] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let main = CGMainDisplayID()
        return ids.enumerated().map { index, id in
            DisplayOption(
                id: id, index: index, bounds: CGDisplayBounds(id), isMain: id == main)
        }
    }

    var selectedDisplay: DisplayOption? {
        displays.first { $0.configValue == config.display } ?? displays.first { $0.isMain }
    }

    /// The mapper does the same math as the driver — the preview must not draw
    /// its own version of the calculation.
    var mapper: ScreenMapper {
        ScreenMapper(
            params: tablet, config: config,
            displayBounds: selectedDisplay?.bounds)
    }

    var curve: PressureCurve {
        PressureCurve(pressure: config.pressure, maxRaw: tablet.pressureMax)
    }

    func resetToDefaults() {
        config = Config()
    }

    // The save waits for the hand to stop moving: the driver re-reads the file on
    // every write.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func save() {
        do {
            try config.save(to: configURL)
            savedAt = Date()
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
