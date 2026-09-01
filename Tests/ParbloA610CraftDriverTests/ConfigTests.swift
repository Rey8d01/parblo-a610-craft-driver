import Foundation
import Testing

@testable import ParbloA610Core

private func parse(_ json: String) -> Config {
    let object = try! JSONSerialization.jsonObject(with: Data(json.utf8))
    return Config(json: object as! [String: Any])
}

@Suite("Config parsing")
struct ConfigTests {

    @Test("an empty config gives the default values")
    func empty() {
        #expect(parse("{}") == Config())
    }

    /// The file the driver creates on first run must hold exactly the same values
    /// as the ones written in the code. If it does not, behaviour before and after
    /// the first edit of the config would differ for no reason at all.
    @Test("the default file matches the defaults in the code")
    func defaultFileMatchesCode() {
        #expect(parse(Config.defaultJSON) == Config())
    }

    @Test("one key given, the rest stay unchanged")
    func partial() {
        let c = parse(#"{"orientation": 90}"#)
        #expect(c.orientation == 90)
        #expect(c.display == Config().display)
        #expect(c.pressure == Config().pressure)
    }

    @Test("an invalid rotation is ignored")
    func badOrientation() {
        #expect(parse(#"{"orientation": 45}"#).orientation == 0)
        #expect(parse(#"{"orientation": -90}"#).orientation == 0)
    }

    @Test("an unknown button action does not break the setting")
    func unknownButtonAction() {
        let c = parse(#"{"penButtons": {"barrel1": "teleportation"}}"#)
        #expect(c.penButtons.barrel1 == Config().penButtons.barrel1)
    }

    @Test("a known button action is applied")
    func knownButtonAction() {
        let c = parse(#"{"penButtons": {"barrel1": "middleClick", "barrel2": "none"}}"#)
        #expect(c.penButtons.barrel1 == .middleClick)
        #expect(c.penButtons.barrel2 == .none)
    }

    @Test("values of the wrong type are not applied")
    func wrongTypes() {
        let c = parse(#"{"display": 5, "lockAspectRatio": "yes", "orientation": "90"}"#)
        #expect(c == Config())
    }

    @Test("a nested object of the wrong shape is ignored completely")
    func wrongNestedShape() {
        #expect(parse(#"{"pressure": [1, 2, 3]}"#).pressure == Config().pressure)
        #expect(parse(#"{"activeArea": "all"}"#).activeArea == Config().activeArea)
    }

    /// Gamma goes into pow(): zero would turn any pressure into one, and a
    /// negative value would give infinity at zero pressure.
    @Test("a bad gamma is dropped")
    func badGamma() {
        for bad in ["0", "-1.5", "0.0"] {
            #expect(
                parse("{\"pressure\": {\"gamma\": \(bad)}}").pressure.gamma
                    == Config().pressure.gamma)
        }
        #expect(parse(#"{"pressure": {"gamma": 2.0}}"#).pressure.gamma == 2.0)
    }

    @Test("pressure limits outside 0…1 are dropped")
    func badPressureBounds() {
        let c = parse(#"{"pressure": {"min": -0.5, "max": 2047}}"#)
        #expect(c.pressure == Config().pressure)
    }

    /// A fraction is easy to mix up with tablet counts or millimetres.
    @Test("an active area outside 0…1 is dropped")
    func badActiveArea() {
        #expect(parse(#"{"activeArea": {"width": 40000}}"#).activeArea == Config().activeArea)
        #expect(parse(#"{"activeArea": {"x": -0.2}}"#).activeArea == Config().activeArea)
        #expect(parse(#"{"activeArea": {"height": 0}}"#).activeArea == Config().activeArea)
        #expect(parse(#"{"activeArea": {"width": 0.5}}"#).activeArea.width == 0.5)
    }

    @Test("pressure and active area are read in full")
    func fullValues() {
        let c = parse(
            #"""
            {
              "display": "1",
              "activeArea": { "x": 0.1, "y": 0.2, "width": 0.7, "height": 0.6 },
              "lockAspectRatio": false,
              "orientation": 270,
              "pressure": { "min": 0.05, "max": 0.9, "gamma": 1.4 }
            }
            """#)
        #expect(c.display == "1")
        #expect(c.activeArea == Config.Area(x: 0.1, y: 0.2, width: 0.7, height: 0.6))
        #expect(c.lockAspectRatio == false)
        #expect(c.orientation == 270)
        #expect(c.pressure == Config.Pressure(min: 0.05, max: 0.9, gamma: 1.4))
    }
}

@Suite("Config writing")
struct ConfigWritingTests {

    /// The settings app writes the file and the driver reads it. If writing and
    /// parsing do not match, settings would be lost without any message.
    @Test("what is written reads back without loss")
    func roundTrip() throws {
        let original = Config(
            display: "1",
            activeArea: Config.Area(x: 0.1, y: 0.25, width: 0.8, height: 0.5),
            lockAspectRatio: false,
            orientation: 270,
            pressure: Config.Pressure(min: 0.05, max: 0.9, gamma: 1.4),
            penButtons: Config.PenButtons(barrel1: .middleClick, barrel2: .none))

        let object = try JSONSerialization.jsonObject(with: Data(original.json.utf8))
        #expect(Config(json: object as! [String: Any]) == original)
    }
}
