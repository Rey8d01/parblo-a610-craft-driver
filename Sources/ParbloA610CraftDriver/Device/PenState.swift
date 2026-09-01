import Foundation
import ParbloA610Core

/// A parsed Report ID 7 from interface 0.
struct PenState: Equatable {
    var x = 0  // 0..xMax
    var y = 0  // 0..yMax
    var pressure = 0  // 0..pressureMax
    var tipSwitch = false
    var barrel1 = false  // lower barrel button, bit 1
    var barrel2 = false  // upper barrel button, bit 2
    var invert = false  // bit 3, never seen from this tablet
    var inRange = false
}

enum ReportParser {
    /// The only report we care about.
    static let penReportID: UInt32 = 7

    /// Payload without the report ID: flags + X + Y + pressure.
    private static let payloadLength = 7

    /// The two bits that say where the pen is.
    ///
    /// The interface 0 descriptor puts `Usage(In Range)` on bit 6 and calls bit 7
    /// padding (`Input (Constant)`). The device does neither. Measured over 6535
    /// reports: bit 7 is set in every single one, so it carries no information, and
    /// bit 6 is set only in the report that says the pen has **left** — the reverse
    /// of the declared meaning. Every one of the 8 removals in that run ended with
    /// `0xC0` as the last report before the stream stopped.
    ///
    /// So the pen is in range while bit 7 is set and bit 6 is clear. The silence
    /// timeout in `TabletEventEmitter` stays as a backup for the case where the
    /// stream simply stops — the cable is pulled, the tablet loses full mode.
    private static let inRangeBit: UInt8 = 0x80
    private static let outOfRangeBit: UInt8 = 0x40

    static func parse(reportID: UInt32, buffer: UnsafeBufferPointer<UInt8>) -> PenState? {
        guard reportID == penReportID else { return nil }

        // The buffer may start with the report ID, or it may not — it depends on how
        // the report was delivered (see the same branch in tools/hidwatch.c).
        let offset = (buffer.count > payloadLength && buffer[0] == UInt8(reportID)) ? 1 : 0
        guard buffer.count - offset >= payloadLength else { return nil }

        func u16(_ i: Int) -> Int {
            Int(buffer[offset + i]) | (Int(buffer[offset + i + 1]) << 8)
        }

        let flags = buffer[offset]
        return PenState(
            x: u16(1),
            y: u16(3),
            pressure: u16(5),
            tipSwitch: flags & 0x01 != 0,
            barrel1: flags & 0x02 != 0,
            barrel2: flags & 0x04 != 0,
            invert: flags & 0x08 != 0,
            inRange: flags & inRangeBit != 0 && flags & outOfRangeBit == 0
        )
    }
}
