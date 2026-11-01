import Testing
@testable import smudge

/// Report descriptor of the touchscreen interface of an ILITEK panel (222a:0001).
private let ilitek = bytes(
    "050d0904a10185040922a102050d9501750609511500253f81020942250175019501810275019501810305017510550e",
    "65110930268025350046150c8142093126802546cb068142c0050d0922a102050d9501750609511500253f8102094225",
    "0175019501810275019501810305017510550e65110930268025350046150c8142093126802546cb068142c0050d0922",
    "a102050d9501750609511500253f81020942250175019501810275019501810305017510550e65110930268025350046",
    "150c8142093126802546cb068142c0050d0922a102050d9501750609511500253f810209422501750195018102750195",
    "01810305017510550e65110930268025350046150c8142093126802546cb068142c0050d0922a102050d950175060951",
    "1500253f81020942250175019501810275019501810305017510550e65110930268025350046150c8142093126802546",
    "cb068142c0050d0922a102050d9501750609511500253f81020942250175019501810275019501810305017510550e65",
    "110930268025350046150c8142093126802546cb068142c0050d0922a102050d9501750609511500253f810209422501",
    "75019501810275019501810305017510550e65110930268025350046150c8142093126802546cb068142c0050d0922a1",
    "02050d9501750609511500253f81020942250175019501810275019501810305017510550e6511093026802535004615",
    "0c8142093126802546cb068142c0050d0922a102050d9501750609511500253f81020942250175019501810275019501",
    "810305017510550e65110930268025350046150c8142093126802546cb068142c0050d0922a102050d95017506095115",
    "00253f81020942250175019501810275019501810305017510550e65110930268025350046150c8142093126802546cb",
    "068142c0050d09565500650027ffffff7f9501752081020954257f95017508810275089508810385060955250a750895",
    "01b1020600ff09c58506150026ff007508960001b102c0"
)

private func bytes(_ hex: String...) -> [UInt8] {
    let digits = Array(hex.joined())
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
}

private func contact(_ id: Int64) -> Contact { Contact(id: id, x: 0, y: 0) }

@Test func ilitekLayout() throws {
    let layout = try #require(Layout(HIDDescriptor(ilitek)))
    #expect(layout.reportID == 4)
    #expect(layout.slots.count == 10)
    #expect(layout.contactCount != nil)
    #expect(layout.slots[0].x.logicalMax == 9600)

    // One contact (ID 3) at the horizontal centre, top edge. Per slot: 6-bit ID, tip,
    // padding, 16-bit X, 16-bit Y; then scan time (32 bits), contact count, padding.
    var payload = [UInt8](repeating: 0, count: 63)
    payload[0] = 3 | 1 << 6
    payload[1] = 0xC0; payload[2] = 0x12 // 4800
    payload[54] = 1
    let contacts = payload.withUnsafeBufferPointer { layout.slots($0, firstIndex: 0) }.compactMap { $0 }
    #expect(layout.count(payload.withUnsafeBufferPointer { $0 }) == 1)
    #expect(contacts.count == 1)
    #expect(contacts.first?.id == 3)
    #expect(contacts.first?.x == 0.5)
    #expect(contacts.first?.y == 0)
}

@Test func unsignedLogicalMaxUsesItemWidth() {
    // Logical Max 0xFF in one byte, Report Size 16: the maximum is 255, not 65535.
    let descriptor = HIDDescriptor(bytes("05010902a101" + "0930" + "1500" + "25ff" + "7510" + "9501" + "8102" + "c0"))
    #expect(descriptor.fields.first?.logicalMax == 255)
}

@Test func signedLogicalMaxWhenMinimumIsNegative() {
    let descriptor = HIDDescriptor(bytes("05010902a101" + "0930" + "1581" + "257f" + "7508" + "9501" + "8106" + "c0"))
    #expect(descriptor.fields.first?.logicalMin == -127)
    #expect(descriptor.fields.first?.logicalMax == 127)
}

@Test func explicitUsagesAndRangesKeepTheirOrder() {
    // Usage X, then Usage Minimum/Maximum Y..Y, Report Count 2: fields are X and Y.
    let descriptor = HIDDescriptor(bytes("0501" + "0930" + "1931" + "2931" + "1500" + "257f" + "7508" + "9502" + "8102"))
    #expect(descriptor.fields.map(\.usage) == [0x30, 0x31])
}

@Test func fieldsInNestedCollectionsBelongToTheirFinger() throws {
    // Finger collection holding Tip Switch directly and X/Y inside a Physical collection.
    let descriptor = HIDDescriptor(bytes(
        "050d0904a101" + "8501" + "0922a102"
            + "0942" + "1500" + "2501" + "7501" + "9501" + "8102" + "7507" + "8103"
            + "0501" + "0901a100" + "0930" + "0931" + "26ff0f" + "7510" + "9502" + "8102" + "c0"
            + "c0" + "c0"
    ))
    let layout = try #require(Layout(descriptor))
    #expect(layout.slots.count == 1)
    #expect(layout.slots[0].x.logicalMax == 0x0FFF)
}

@Test func framesWithoutContactCountPassThrough() {
    var frames = FrameAssembler()
    #expect(frames.add(count: nil, slots: [contact(1), nil, contact(2)])?.map(\.id) == [1, 2])
}

@Test func hybridFramesSpanReports() {
    var frames = FrameAssembler()
    // Three contacts, two slots per report: the first report alone is not a frame.
    #expect(frames.add(count: 3, slots: [contact(1), contact(2)]) == nil)
    #expect(frames.nextSlot == 2)
    let frame = frames.add(count: 0, slots: [contact(3), contact(9)])
    #expect(frame?.map(\.id) == [1, 2, 3])
}

@Test func hybridLiftedContactsStillCount() {
    var frames = FrameAssembler()
    #expect(frames.add(count: 2, slots: [nil, contact(2)])?.map(\.id) == [2])
}

@Test func emptyFrameWhenAllLifted() {
    var frames = FrameAssembler()
    #expect(frames.add(count: 0, slots: [nil, nil])?.isEmpty == true)
}

@Test func newCountDropsIncompleteFrame() {
    var frames = FrameAssembler()
    #expect(frames.add(count: 4, slots: [contact(1), contact(2)]) == nil)
    // The continuation was lost; the next frame starts over.
    #expect(frames.add(count: 1, slots: [contact(5), nil])?.map(\.id) == [5])
}
