import CoreGraphics
import Foundation

package struct Config: Equatable {
    package struct Area: Equatable {
        package var x: Double
        package var y: Double
        package var width: Double
        package var height: Double

        package init(x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    package struct Pressure: Equatable {
        /// Dead zone at the bottom and saturation at the top, as fractions of the raw range.
        package var min: Double
        package var max: Double
        /// < 1 is softer (a light press gives more), > 1 is harder.
        package var gamma: Double

        package init(min: Double = 0.02, max: Double = 0.95, gamma: Double = 0.75) {
            self.min = min
            self.max = max
            self.gamma = gamma
        }
    }

    package enum ButtonAction: String, Equatable, CaseIterable {
        case none, leftClick, rightClick, middleClick

        package var mouseButton: CGMouseButton? {
            switch self {
            case .none: return nil
            case .leftClick: return .left
            case .rightClick: return .right
            case .middleClick: return .center
            }
        }

        /// Name shown in the settings interface.
        package var title: String {
            switch self {
            case .none: return "nothing"
            case .leftClick: return "left click"
            case .rightClick: return "right click"
            case .middleClick: return "middle click"
            }
        }
    }

    package struct PenButtons: Equatable {
        package var barrel1: ButtonAction  // lower barrel button
        package var barrel2: ButtonAction  // upper barrel button

        package init(barrel1: ButtonAction = .rightClick, barrel2: ButtonAction = .middleClick) {
            self.barrel1 = barrel1
            self.barrel2 = barrel2
        }
    }

    /// `main`, or the screen number in the list of active displays, counting from zero.
    package var display: String
    package var activeArea: Area
    package var lockAspectRatio: Bool
    /// 0, 90, 180 or 270 degrees.
    package var orientation: Int
    package var pressure: Pressure
    package var penButtons: PenButtons

    package init(
        display: String = "main",
        activeArea: Area = Area(),
        lockAspectRatio: Bool = true,
        orientation: Int = 0,
        pressure: Pressure = Pressure(),
        penButtons: PenButtons = PenButtons()
    ) {
        self.display = display
        self.activeArea = activeArea
        self.lockAspectRatio = lockAspectRatio
        self.orientation = orientation
        self.pressure = pressure
        self.penButtons = penButtons
    }
}

extension Config {
    /// Parsing is forgiving on purpose: a missing value falls back to the default, and so
    /// does a value we do not understand. People edit the config by hand, and a typo must
    /// not bring the driver down.
    package init(json: [String: Any]) {
        self.init()

        if let value = json["display"] as? String { display = value }
        if let value = json["lockAspectRatio"] as? Bool { lockAspectRatio = value }
        if let value = json["orientation"] as? Int, [0, 90, 180, 270].contains(value) {
            orientation = value
        }

        // The area is given as fractions of the whole tablet surface, so anything outside
        // 0...1 is certainly wrong: most often raw counts or millimetres.
        if let area = json["activeArea"] as? [String: Any] {
            activeArea.x = (area["x"] as? Double).flatMap(Self.fraction) ?? activeArea.x
            activeArea.y = (area["y"] as? Double).flatMap(Self.fraction) ?? activeArea.y
            activeArea.width =
                (area["width"] as? Double).flatMap(Self.positiveFraction) ?? activeArea.width
            activeArea.height =
                (area["height"] as? Double).flatMap(Self.positiveFraction) ?? activeArea.height
        }

        if let value = json["pressure"] as? [String: Any] {
            pressure.min = (value["min"] as? Double).flatMap(Self.fraction) ?? pressure.min
            pressure.max = (value["max"] as? Double).flatMap(Self.fraction) ?? pressure.max
            // Gamma goes into pow(): zero would turn any pressure into one, and a negative
            // value would give infinity at zero pressure.
            if let gamma = value["gamma"] as? Double, gamma > 0, gamma.isFinite {
                pressure.gamma = gamma
            }
        }

        if let value = json["penButtons"] as? [String: Any] {
            if let raw = value["barrel1"] as? String, let a = ButtonAction(rawValue: raw) {
                penButtons.barrel1 = a
            }
            if let raw = value["barrel2"] as? String, let a = ButtonAction(rawValue: raw) {
                penButtons.barrel2 = a
            }
        }
    }

    private static func fraction(_ value: Double) -> Double? {
        (value.isFinite && value >= 0 && value <= 1) ? value : nil
    }

    private static func positiveFraction(_ value: Double) -> Double? {
        (value.isFinite && value > 0 && value <= 1) ? value : nil
    }

    /// The opposite of `init(json:)`. The settings app needs it: the app writes the file,
    /// and the driver picks it up by itself — there is no other link between them.
    ///
    /// The format matches `defaultJSON` on purpose: the file is edited by hand too, so it
    /// must not change its look after the first save from the interface.
    package var json: String {
        func f(_ value: Double) -> String { String(format: "%g", value) }
        return """
            {
              "display": "\(display)",
              "activeArea": { "x": \(f(activeArea.x)), "y": \(f(activeArea.y)), \
            "width": \(f(activeArea.width)), "height": \(f(activeArea.height)) },
              "lockAspectRatio": \(lockAspectRatio),
              "orientation": \(orientation),
              "pressure": { "min": \(f(pressure.min)), "max": \(f(pressure.max)), \
            "gamma": \(f(pressure.gamma)) },
              "penButtons": { "barrel1": "\(penButtons.barrel1.rawValue)", \
            "barrel2": "\(penButtons.barrel2.rawValue)" }
            }

            """
    }

    /// Writes the config where the driver reads it from.
    package func save(to url: URL = ConfigStore.url) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The file the driver creates on the first run. It is built from the same defaults
    /// that are written in the code, because otherwise the two would drift apart at the
    /// very first edit, and the file would describe behaviour the owner does not get.
    package static var defaultJSON: String { Config().json }
}
