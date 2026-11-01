import Foundation

/// One value slot inside a HID report, resolved from the report descriptor.
struct HIDField {
    enum Kind { case input, output, feature }

    struct Collection {
        /// Unique across the descriptor, in order of appearance.
        let index: Int
        /// Usage page << 16 | usage id.
        let usage: UInt32
    }

    let kind: Kind
    let reportID: UInt8
    let usagePage: UInt32
    let usage: UInt32
    /// Bit offset inside the report payload (excluding the report ID byte).
    let bitOffset: Int
    let bitSize: Int
    let logicalMin: Int64
    let logicalMax: Int64
    let isConstant: Bool
    /// Enclosing collections, outermost first.
    let collections: [Collection]

    func matches(_ page: UInt32, _ id: UInt32) -> Bool { usagePage == page && usage == id }

    /// The innermost enclosing collection with the given usage.
    func collection(_ page: UInt32, _ id: UInt32) -> Collection? {
        collections.last { $0.usage == page << 16 | id }
    }

    func read(_ payload: UnsafeBufferPointer<UInt8>) -> Int64? {
        guard bitSize > 0, bitOffset + bitSize <= payload.count * 8 else { return nil }
        var raw: UInt64 = 0
        for i in 0..<bitSize {
            let bit = bitOffset + i
            if payload[bit / 8] & (1 << (bit % 8)) != 0 { raw |= 1 << UInt64(i) }
        }
        if logicalMin < 0, bitSize < 64, raw & (1 << UInt64(bitSize - 1)) != 0 {
            return Int64(bitPattern: raw | (~0 << UInt64(bitSize)))
        }
        return Int64(bitPattern: raw)
    }

    func write(_ value: Int64, into payload: inout [UInt8]) {
        let raw = UInt64(bitPattern: value)
        for i in 0..<bitSize {
            let bit = bitOffset + i
            if raw & (1 << UInt64(i)) != 0 {
                payload[bit / 8] |= 1 << (bit % 8)
            } else {
                payload[bit / 8] &= ~(1 << (bit % 8))
            }
        }
    }
}

/// Minimal HID report descriptor parser: enough to locate digitizer fields
/// and feature reports without relying on the order IOKit delivers values in.
struct HIDDescriptor {
    private(set) var fields: [HIDField] = []
    private var bitsPerReport: [HIDField.Kind: [UInt8: Int]] = [:]

    var usesReportIDs: Bool { fields.contains { $0.reportID != 0 } }

    /// Payload length in bytes (without the report ID byte).
    func payloadLength(_ kind: HIDField.Kind, _ reportID: UInt8) -> Int {
        ((bitsPerReport[kind]?[reportID] ?? 0) + 7) / 8
    }

    /// Local usage items in descriptor order; ranges stay unexpanded.
    private enum UsageItem {
        case single(UInt32)
        case range(UInt32, UInt32)

        var count: Int {
            switch self {
            case .single: 1
            case let .range(lo, hi): Int(hi - lo) + 1
            }
        }
    }

    /// The n-th usage of a main item; the last usage repeats for remaining fields (HID 1.11, 6.2.2.8).
    private static func usage(_ items: [UsageItem], at n: Int) -> UInt32 {
        var n = n
        for item in items {
            if n < item.count {
                switch item {
                case let .single(usage): return usage
                case let .range(lo, _): return lo + UInt32(n)
                }
            }
            n -= item.count
        }
        switch items.last {
        case let .single(usage): return usage
        case let .range(_, hi): return hi
        case nil: return 0
        }
    }

    init(_ bytes: [UInt8]) {
        struct Globals {
            var usagePage: UInt32 = 0
            var logicalMin: Int64 = 0
            /// Logical Maximum as signed and as unsigned in its own item width; which one
            /// applies depends on whether Logical Minimum is negative.
            var logicalMaxSigned: Int64 = 0
            var logicalMaxUnsigned: Int64 = 0
            var reportSize = 0
            var reportCount = 0
            var reportID: UInt8 = 0
        }
        var globals = Globals()
        var globalStack: [Globals] = []
        var usages: [UsageItem] = []
        var usageMin: UInt32?
        var usageMax: UInt32?
        var collections: [HIDField.Collection] = []
        var nextCollection = 0

        func qualify(_ value: UInt32, size: Int) -> UInt32 {
            size == 4 ? value : (globals.usagePage << 16) | value
        }

        func closeRangeIfComplete() {
            guard let lo = usageMin, let hi = usageMax else { return }
            if lo <= hi { usages.append(.range(lo, hi)) }
            usageMin = nil
            usageMax = nil
        }

        func resetLocals() {
            usages = []
            usageMin = nil
            usageMax = nil
        }

        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            if prefix == 0xFE { // long item
                guard i + 1 < bytes.count else { break }
                i += 3 + Int(bytes[i + 1])
                continue
            }
            let size = [0, 1, 2, 4][Int(prefix & 0x03)]
            let type = (prefix >> 2) & 0x03
            let tag = prefix >> 4
            guard i + 1 + size <= bytes.count else { break }
            var unsigned: UInt32 = 0
            for b in 0..<size { unsigned |= UInt32(bytes[i + 1 + b]) << (8 * b) }
            let signed: Int64 = switch size {
            case 1: Int64(Int8(bitPattern: UInt8(unsigned)))
            case 2: Int64(Int16(bitPattern: UInt16(unsigned)))
            case 4: Int64(Int32(bitPattern: unsigned))
            default: 0
            }
            i += 1 + size

            switch (type, tag) {
            // Main items
            case (0, 0x8), (0, 0x9), (0, 0xB):
                let kind: HIDField.Kind = tag == 0x8 ? .input : tag == 0x9 ? .output : .feature
                let rid = globals.reportID
                var offset = bitsPerReport[kind]?[rid] ?? 0
                let logicalMax = globals.logicalMin < 0 ? globals.logicalMaxSigned : globals.logicalMaxUnsigned
                for n in 0..<globals.reportCount {
                    let qualified = Self.usage(usages, at: n)
                    fields.append(HIDField(
                        kind: kind, reportID: rid,
                        usagePage: qualified >> 16, usage: qualified & 0xFFFF,
                        bitOffset: offset, bitSize: globals.reportSize,
                        logicalMin: globals.logicalMin, logicalMax: logicalMax,
                        isConstant: unsigned & 0x01 != 0,
                        collections: collections
                    ))
                    offset += globals.reportSize
                }
                bitsPerReport[kind, default: [:]][rid] = offset
                resetLocals()
            case (0, 0xA):
                let usage = usages.isEmpty ? (usageMin ?? 0) : Self.usage(usages, at: 0)
                collections.append(HIDField.Collection(index: nextCollection, usage: usage))
                nextCollection += 1
                resetLocals()
            case (0, 0xC):
                _ = collections.popLast()
                resetLocals()
            // Global items
            case (1, 0x0): globals.usagePage = unsigned
            case (1, 0x1): globals.logicalMin = signed
            case (1, 0x2):
                globals.logicalMaxSigned = signed
                globals.logicalMaxUnsigned = Int64(unsigned)
            case (1, 0x7): globals.reportSize = Int(unsigned)
            case (1, 0x8): globals.reportID = UInt8(truncatingIfNeeded: unsigned)
            case (1, 0x9): globals.reportCount = Int(unsigned)
            case (1, 0xA): globalStack.append(globals)
            case (1, 0xB): globals = globalStack.popLast() ?? globals
            // Local items
            case (2, 0x0): usages.append(.single(qualify(unsigned, size: size)))
            case (2, 0x1):
                usageMin = qualify(unsigned, size: size)
                closeRangeIfComplete()
            case (2, 0x2):
                usageMax = qualify(unsigned, size: size)
                closeRangeIfComplete()
            default: break
            }
        }
    }
}
