import Foundation
import IOKit.hid

/// A single finger in a frame, in normalized panel coordinates (0...1, origin top-left).
struct Contact {
    let id: Int64
    let x: Double
    let y: Double
}

private let digitizerPage: UInt32 = 0x0D
private let genericDesktopPage: UInt32 = 0x01
private let vendorPage: UInt32 = 0xFF00

private enum Usage {
    static let touchScreen: UInt32 = 0x04
    static let finger: UInt32 = 0x22
    static let tipSwitch: UInt32 = 0x42
    static let contactID: UInt32 = 0x51
    static let inputMode: UInt32 = 0x52
    static let contactCount: UInt32 = 0x54
    static let x: UInt32 = 0x30
    static let y: UInt32 = 0x31
    /// Windows certification blob; reading it is what flips many panels out of mouse mode.
    static let certificationBlob: UInt32 = 0xC5
}

/// Report layout of one multi-touch digitizer.
private struct Layout {
    struct Slot {
        let tip: HIDField
        let id: HIDField?
        let x: HIDField
        let y: HIDField
    }

    let reportID: UInt8
    let slots: [Slot]
    let contactCount: HIDField?

    init?(_ descriptor: HIDDescriptor) {
        let inputs = descriptor.fields.filter { $0.kind == .input && !$0.isConstant }
        let fingerCollections = Dictionary(grouping: inputs.filter {
            $0.collectionUsage == (digitizerPage << 16 | Usage.finger)
        }, by: \.collection)

        var slots: [(Int, Slot)] = []
        for (collection, fields) in fingerCollections {
            guard let tip = fields.first(where: { $0.matches(digitizerPage, Usage.tipSwitch) }),
                  let x = fields.first(where: { $0.matches(genericDesktopPage, Usage.x) }),
                  let y = fields.first(where: { $0.matches(genericDesktopPage, Usage.y) })
            else { continue }
            let id = fields.first { $0.matches(digitizerPage, Usage.contactID) }
            slots.append((collection, Slot(tip: tip, id: id, x: x, y: y)))
        }
        guard let first = slots.first else { return nil }

        let rid = first.1.tip.reportID
        reportID = rid
        self.slots = slots.sorted { $0.0 < $1.0 }.map(\.1).filter { $0.tip.reportID == rid }
        contactCount = inputs.first { $0.reportID == rid && $0.matches(digitizerPage, Usage.contactCount) }
    }

    func contacts(_ payload: UnsafeBufferPointer<UInt8>) -> [Contact] {
        // Hybrid-mode devices put the real count only in the first report of a frame;
        // this panel reports all slots at once, so a missing count means "all slots".
        let count = contactCount.flatMap { $0.read(payload) }.map(Int.init) ?? slots.count
        return slots.prefix(max(0, min(count, slots.count))).enumerated().compactMap { index, slot in
            guard slot.tip.read(payload) == 1,
                  let rx = slot.x.read(payload), let ry = slot.y.read(payload)
            else { return nil }
            return Contact(
                id: slot.id?.read(payload) ?? Int64(index),
                x: normalize(rx, slot.x),
                y: normalize(ry, slot.y)
            )
        }
    }

    private func normalize(_ value: Int64, _ field: HIDField) -> Double {
        let span = Double(field.logicalMax - field.logicalMin)
        guard span > 0 else { return 0 }
        return min(1, max(0, Double(value - field.logicalMin) / span))
    }
}

/// Owns one HID touchscreen: switches it to multi-touch mode and turns reports into frames.
final class TouchPanel {
    let device: IOHIDDevice
    let name: String
    private let descriptor: HIDDescriptor
    private let layout: Layout
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize: Int
    var onFrame: (([Contact]) -> Void)?

    init?(_ device: IOHIDDevice) {
        guard let data = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data else { return nil }
        let descriptor = HIDDescriptor([UInt8](data))
        guard let layout = Layout(descriptor) else { return nil }
        self.device = device
        self.descriptor = descriptor
        self.layout = layout
        name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "touchscreen"
        bufferSize = max(64, IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0)
        buffer = .allocate(capacity: bufferSize)
    }

    deinit {
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, nil, nil)
        buffer.deallocate()
    }

    var summary: String {
        "\(name): \(layout.slots.count) contacts, report \(layout.reportID)"
    }

    func start() {
        activateMultiTouch()
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, { context, result, _, _, reportID, report, length in
            guard result == kIOReturnSuccess, let context else { return }
            Unmanaged<TouchPanel>.fromOpaque(context).takeUnretainedValue()
                .handle(reportID: UInt8(truncatingIfNeeded: reportID), report: report, length: length)
        }, context)
    }

    /// Panels without a usable driver stay in mouse-emulation mode. Do what Windows does:
    /// set Input Mode to multi-touch when present and read the certification blob.
    func activateMultiTouch() {
        let features = descriptor.fields.filter { $0.kind == .feature }

        if let mode = features.first(where: { $0.matches(digitizerPage, Usage.inputMode) }) {
            var payload = [UInt8](repeating: 0, count: descriptor.payloadLength(.feature, mode.reportID))
            mode.write(2, into: &payload)
            let report = mode.reportID == 0 ? payload : [mode.reportID] + payload
            let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(mode.reportID), report, report.count)
            log("\(name): set input mode -> \(hex(result))")
        }

        // The blob is one usage repeated per byte; read each report only once.
        let blobReports = Set(features.filter { $0.matches(vendorPage, Usage.certificationBlob) }.map(\.reportID))
        for reportID in blobReports {
            var length = descriptor.payloadLength(.feature, reportID) + 1
            var report = [UInt8](repeating: 0, count: length)
            let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), &report, &length)
            log("\(name): read certification blob -> \(hex(result))")
        }
    }

    private func handle(reportID: UInt8, report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard reportID == layout.reportID else { return }
        // Input report callbacks include the report ID byte when the device uses IDs.
        let skip = descriptor.usesReportIDs ? 1 : 0
        guard length > skip else { return }
        let payload = UnsafeBufferPointer(start: report + skip, count: length - skip)
        onFrame?(layout.contacts(payload))
    }
}

private func hex(_ value: IOReturn) -> String { String(format: "0x%X", value) }
