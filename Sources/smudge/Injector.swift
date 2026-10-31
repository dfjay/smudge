import CoreGraphics

/// Posts synthetic input into the HID event stream.
enum Injector {
    enum Phase: Int64 {
        case began = 1, changed = 2, ended = 4
    }

    private static let source = CGEventSource(stateID: .hidSystemState)

    static func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clicks)
        event.post(tap: .cghidEventTap)
    }

    static func click(at point: CGPoint, button: CGMouseButton = .left, clicks: Int64 = 1) {
        let (down, up): (CGEventType, CGEventType) = button == .right
            ? (.rightMouseDown, .rightMouseUp)
            : (.leftMouseDown, .leftMouseUp)
        mouse(down, at: point, button: button, clicks: clicks)
        mouse(up, at: point, button: button, clicks: clicks)
    }

    enum ScrollPhase {
        case began, changed, ended
        case momentumBegan, momentum, momentumEnded
    }

    private static var scrollRemainder = CGPoint.zero

    static var cursor: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Continuous (trackpad-style) scroll in points at the cursor; positive dy scrolls content down.
    /// No explicit location: posting one would pin the cursor there.
    static func scroll(dx: Double, dy: Double, phase: ScrollPhase) {
        if phase == .began || phase == .momentumBegan { scrollRemainder = .zero }
        let x = dx + scrollRemainder.x, y = dy + scrollRemainder.y
        let ix = Int32(x.rounded(.towardZero)), iy = Int32(y.rounded(.towardZero))
        scrollRemainder = CGPoint(x: x - Double(ix), y: y - Double(iy))

        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        switch phase {
        case .began: event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        case .changed: event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        case .ended: event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
        case .momentumBegan: event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
        case .momentum: event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
        case .momentumEnded: event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 3)
        }
        event.post(tap: .cghidEventTap)
    }

    // Undocumented WindowServer gesture fields, as used by trackpad gesture synthesizers.
    private static let gestureEventType: UInt32 = 29 // kCGSEventGesture
    private static let gestureHIDTypeField = CGEventField(rawValue: 110)!
    private static let gestureZoomValueField = CGEventField(rawValue: 113)!
    private static let gesturePhaseField = CGEventField(rawValue: 132)!
    private static let hidEventTypeZoom: Int64 = 8

    /// Pinch-to-zoom; `delta` is the relative change in scale since the previous event.
    static func magnify(_ delta: Double, at point: CGPoint, phase: Phase) {
        guard let event = CGEvent(source: source), let type = CGEventType(rawValue: gestureEventType) else { return }
        event.type = type
        event.location = point
        event.setIntegerValueField(gestureHIDTypeField, value: hidEventTypeZoom)
        event.setDoubleValueField(gestureZoomValueField, value: delta)
        event.setIntegerValueField(gesturePhaseField, value: phase.rawValue)
        event.post(tap: .cghidEventTap)
    }
}
