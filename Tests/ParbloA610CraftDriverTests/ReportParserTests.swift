import Testing

@testable import ParbloA610CraftDriver

private func parse(_ bytes: [UInt8], id: UInt32 = 7) -> PenState? {
    bytes.withUnsafeBufferPointer { ReportParser.parse(reportID: id, buffer: $0) }
}

@Suite("Report ID 7 parsing")
struct ReportParserTests {

    /// Numbers from string descriptor 100 of the real device: 40000, 24000, 2047.
    @Test("bytes are read with the low byte first")
    func littleEndian() {
        let s = parse([7, 0x81, 0x40, 0x9C, 0xC0, 0x5D, 0xFF, 0x07])
        #expect(s?.x == 40000)
        #expect(s?.y == 24000)
        #expect(s?.pressure == 2047)
    }

    /// The buffer can come with the report number as the first byte, or without it.
    @Test("a report ID at the start of the buffer is dropped")
    func stripsReportID() {
        let withID = parse([7, 0x81, 0x40, 0x9C, 0xC0, 0x5D, 0xFF, 0x07])
        let without = parse([0x81, 0x40, 0x9C, 0xC0, 0x5D, 0xFF, 0x07])
        #expect(withID == without)
    }

    /// The descriptor says In Range is on bit 6 and bit 7 is padding. The device
    /// does the opposite: bit 7 is always set, and bit 6 marks the pen leaving.
    /// Every value below was recorded from the tablet.
    @Test("flags are read as the device sends them")
    func flags() {
        let hover = parse([7, 0x80, 0, 0, 0, 0, 0, 0])
        #expect(hover?.inRange == true)
        #expect(hover?.tipSwitch == false)

        let touch = parse([7, 0x81, 0, 0, 0, 0, 0, 0])
        #expect(touch?.tipSwitch == true)
        #expect(touch?.inRange == true)

        // 0xC0 is the last report before the stream stops. Reading bit 7 alone
        // kept the pen in range and left the exit to a 250 ms timeout.
        let gone = parse([7, 0xC0, 0, 0, 0, 0, 0, 0])
        #expect(gone?.inRange == false)
        #expect(gone?.tipSwitch == false)
    }

    /// The upper barrel button arrives on bit 2, which the descriptor calls
    /// Eraser. Reading it as an eraser made the pen enter the range as an eraser
    /// whenever that button was held, and the middle click never happened.
    @Test("both barrel buttons come from the bits the device really uses")
    func barrelButtons() {
        let lower = parse([7, 0x82, 0, 0, 0, 0, 0, 0])
        #expect(lower?.barrel1 == true)
        #expect(lower?.barrel2 == false)

        let upper = parse([7, 0x84, 0, 0, 0, 0, 0, 0])
        #expect(upper?.barrel2 == true)
        #expect(upper?.barrel1 == false)

        // Measured too: the tip and the upper button together.
        let upperWithTip = parse([7, 0x85, 0, 0, 0, 0, 0, 0])
        #expect(upperWithTip?.barrel2 == true)
        #expect(upperWithTip?.tipSwitch == true)

        // Bit 5 is what the descriptor claims for this button. The device never
        // sets it, so nothing may depend on it.
        let bit5 = parse([7, 0xA0, 0, 0, 0, 0, 0, 0])
        #expect(bit5?.barrel2 == false)
    }

    @Test("a report ID we do not own is not parsed")
    func wrongReportID() {
        #expect(parse([10, 0x81, 0, 0, 0, 0, 0, 0], id: 10) == nil)
    }

    @Test("a short buffer is not parsed and stays in bounds")
    func tooShort() {
        #expect(parse([7, 0x81, 0x40]) == nil)
        #expect(parse([]) == nil)
    }

    @Test("a long buffer is parsed from its first bytes")
    func paddedBuffer() {
        let padded = parse(
            [7, 0x81, 0x40, 0x9C, 0xC0, 0x5D, 0xFF, 0x07] + [UInt8](repeating: 0, count: 56))
        #expect(padded?.x == 40000)
        #expect(padded?.pressure == 2047)
    }
}
