import Foundation

/// Raw pressure → 0.0…1.0, the way `kCGTabletEventPointPressure` expects it.
///
/// A normal working press on this tablet gives about 1450–1520 out of 2047, that
/// is 0.71–0.74 of the scale: the top quarter is almost out of reach, and all the
/// fine work is squeezed into the lower half. The min and max cut-offs and the
/// gamma give that half back.
package struct PressureCurve {
    private let lower: Double
    private let upper: Double
    private let gamma: Double
    private let maxRaw: Double

    package init(pressure: Config.Pressure, maxRaw: Int) {
        lower = pressure.min
        upper = pressure.max
        gamma = pressure.gamma
        self.maxRaw = Double(maxRaw)
    }

    /// The reverse task: which press on the pen matches the pressure we got on the
    /// output. The settings interface needs it: the app sees the value the driver
    /// has already converted, but the point has to be shown on the input axis.
    package func inputFraction(forOutput output: Double) -> Double {
        let t = gamma == 1 ? output : pow(Swift.max(output, 0), 1 / gamma)
        return Swift.min(Swift.max(lower + t * (upper - lower), 0), 1)
    }

    package func normalized(_ raw: Int) -> Double {
        guard maxRaw > 0 else { return 0 }
        let fraction = Double(raw) / maxRaw
        let span = upper - lower
        guard span > 0 else { return fraction >= upper ? 1 : 0 }
        let t = min(max((fraction - lower) / span, 0), 1)
        return gamma == 1 ? t : pow(t, gamma)
    }
}
