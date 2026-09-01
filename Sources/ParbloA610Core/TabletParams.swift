/// Pen parameters read from the device.
///
/// They live in the shared library because both programs need them: the driver, to
/// compute coordinates, and the settings app, to show the active area in the same units
/// the driver sees it in.
package struct TabletParams: Equatable {
    package let xMax: Int
    package let yMax: Int
    package let pressureMax: Int
    package let resolution: Int  // LPI

    package init(xMax: Int, yMax: Int, pressureMax: Int, resolution: Int) {
        self.xMax = xMax
        self.yMax = yMax
        self.pressureMax = pressureMax
        self.resolution = resolution
    }

    /// The A610 values. The driver reads them from the device and does not rely on these;
    /// the settings app needs them until the tablet has been asked.
    package static let a610 = TabletParams(
        xMax: 40000, yMax: 24000, pressureMax: 2047, resolution: 4000)
}
