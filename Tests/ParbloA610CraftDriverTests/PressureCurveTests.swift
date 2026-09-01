import Testing

@testable import ParbloA610Core

@Suite("Pressure curve")
struct PressureCurveTests {

    @Test("the ends of the range")
    func bounds() {
        let curve = PressureCurve(pressure: Config.Pressure(), maxRaw: 2047)
        #expect(curve.normalized(0) == 0)
        #expect(curve.normalized(2047) == 1)
    }

    @Test("values stay inside 0…1 across the whole scale")
    func staysInRange() {
        let curve = PressureCurve(pressure: Config.Pressure(), maxRaw: 2047)
        for raw in stride(from: 0, through: 2047, by: 17) {
            let v = curve.normalized(raw)
            #expect(v >= 0 && v <= 1)
        }
    }

    @Test("the curve is monotonic: press harder, never get less")
    func monotonic() {
        let curve = PressureCurve(pressure: Config.Pressure(), maxRaw: 2047)
        var previous = -1.0
        for raw in stride(from: 0, through: 2047, by: 7) {
            let v = curve.normalized(raw)
            #expect(v >= previous)
            previous = v
        }
    }

    @Test("gamma 1 gives a linear response")
    func linearGamma() {
        let p = Config.Pressure(min: 0, max: 1, gamma: 1)
        let curve = PressureCurve(pressure: p, maxRaw: 1000)
        #expect(abs(curve.normalized(500) - 0.5) < 1e-9)
    }

    @Test("gamma below one lifts light pressure")
    func softGammaLiftsLowEnd() {
        let soft = PressureCurve(
            pressure: Config.Pressure(min: 0, max: 1, gamma: 0.5), maxRaw: 1000)
        let linear = PressureCurve(
            pressure: Config.Pressure(min: 0, max: 1, gamma: 1), maxRaw: 1000)
        #expect(soft.normalized(250) > linear.normalized(250))
    }

    @Test("degenerate settings do not crash and do not give garbage")
    func degenerate() {
        #expect(PressureCurve(pressure: Config.Pressure(), maxRaw: 0).normalized(100) == 0)

        let flat = PressureCurve(
            pressure: Config.Pressure(min: 0.5, max: 0.5, gamma: 1), maxRaw: 1000)
        #expect(flat.normalized(0) == 0)
        #expect(flat.normalized(1000) == 1)

        let inverted = PressureCurve(
            pressure: Config.Pressure(min: 0.9, max: 0.1, gamma: 1), maxRaw: 1000)
        let v = inverted.normalized(500)
        #expect(v >= 0 && v <= 1)
    }
}
