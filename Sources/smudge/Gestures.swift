import CoreGraphics
import Foundation

/// A finger in screen coordinates; `id` stays the same while the finger is down.
struct Touch {
    let id: Int64
    let point: CGPoint
}

/// Turns frames of screen-space contacts into mouse, scroll and magnify events,
/// following the usual touchscreen pointer emulation (libinput, Windows):
/// the pointer jumps to the finger and one finger is the left button.
///
/// One finger: press = button down, move = drag, lift = button up (taps become clicks).
/// Two fingers: move = scroll (with momentum), pinch = magnify, quick tap = right click.
final class GestureEngine {
    struct Tuning {
        var slop: Double = 12               // points a finger may wander and still count as a double tap
        var scrollSlop: Double = 6          // centroid travel that starts a two-finger scroll
        var pinchSlop: Double = 30          // spread change (points) that starts a pinch
        var doubleClickInterval: TimeInterval = 0.35
        var twoFingerTapTime: TimeInterval = 0.25
        /// Delay before pressing the button, so a second finger can still turn it into a scroll.
        var secondFingerGrace: TimeInterval = 0.08
        var velocityWindow: TimeInterval = 0.08
        var momentumMinSpeed: Double = 60   // points per second
        var momentumFriction: Double = 4.0  // exponential decay rate per second
        /// Pause after a gesture before the pointer goes back, so the app handles the click
        /// while the pointer is still under the finger.
        var returnDelay: TimeInterval = 0.15
        /// Pointer movement (points) that means a mouse or trackpad took over.
        var takeoverDistance: Double = 2
    }

    private enum TwoFingerMode { case undecided, scroll, pinch }

    private struct TwoFinger {
        var mode = TwoFingerMode.undecided
        /// Contact IDs currently taking part, sorted.
        var ids: [Int64]
        var center: CGPoint
        var spread: Double
        /// Spread a pinch is measured against; rebased whenever the fingers change.
        var baseSpread: Double
        let startCenter: CGPoint
        let since: TimeInterval
        /// Centroid travel since touch-down, excluding jumps from fingers landing or lifting.
        var travel = CGPoint.zero
        var samples: [(time: TimeInterval, delta: CGPoint)] = []
    }

    private enum State {
        case idle
        case pressing(id: Int64, start: CGPoint, last: CGPoint, since: TimeInterval)
        case down(id: Int64, last: CGPoint, clicks: Int64)
        case twoFinger(TwoFinger)
        /// The gesture is over but fingers remain; wait until they all lift.
        case ignoring
    }

    private var state = State.idle
    private var pressTimer: DispatchWorkItem?
    private var lastPress: (point: CGPoint, time: TimeInterval, clicks: Int64)?
    private var momentum: (timer: Timer, velocity: CGPoint, point: CGPoint, last: TimeInterval)?
    /// Where the pointer was before touching, if it should go back there afterwards.
    private var home: CGPoint?
    private var pendingReturn: DispatchWorkItem?

    var tuning = Tuning()
    var verbose = false
    /// Put the pointer back after each gesture if it was on another display when the touch began.
    var returnCursor = false
    /// Bounds of the touch display, used to tell whether the pointer was elsewhere.
    var touchBounds: CGRect?

    func handle(_ touches: [Touch], now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // Controllers may report slots in any order; identities, not positions, define fingers.
        let touches = touches.sorted { $0.id < $1.id }

        switch state {
        case .idle:
            guard !touches.isEmpty else { return }
            touchBegan()
            if touches.count == 1 {
                beginPress(touches[0], now: now)
            } else {
                beginTwoFinger(touches, now: now)
            }

        case let .pressing(id, start, _, since):
            if touches.count >= 2 {
                cancelPressTimer()
                beginTwoFinger(touches, now: now)
            } else if let touch = touches.first(where: { $0.id == id }) {
                if distance(touch.point, start) > tuning.slop * 3 {
                    pressAndDrag(id: id, start: start, to: touch.point, now: now)
                } else {
                    state = .pressing(id: id, start: start, last: touch.point, since: since)
                }
            } else {
                // Lifted before the button went down: a tap.
                cancelPressTimer()
                let clicks = press(at: start, now: now)
                Injector.mouse(.leftMouseUp, at: start, clicks: clicks)
                finish(remaining: touches)
            }

        case let .down(id, last, clicks):
            // Extra fingers during a drag are ignored; the pressing finger keeps driving the pointer.
            if let touch = touches.first(where: { $0.id == id }) {
                if touch.point != last { Injector.mouse(.leftMouseDragged, at: touch.point, clicks: clicks) }
                state = .down(id: id, last: touch.point, clicks: clicks)
            } else {
                Injector.mouse(.leftMouseUp, at: last, clicks: clicks)
                finish(remaining: touches)
            }

        case var .twoFinger(gesture):
            if touches.isEmpty {
                endTwoFinger(gesture, now: now)
                finish(remaining: touches)
            } else {
                moveTwoFinger(&gesture, touches, now: now)
                state = .twoFinger(gesture)
            }

        case .ignoring:
            if touches.isEmpty { finish(remaining: touches) }
        }
    }

    /// Abandons the current gesture without producing a click, e.g. when the panel disconnects.
    func cancel() {
        cancelPressTimer()
        switch state {
        case let .down(_, last, clicks):
            Injector.mouse(.leftMouseUp, at: last, clicks: clicks)
        case let .twoFinger(gesture) where gesture.mode == .scroll:
            Injector.scroll(dx: 0, dy: 0, phase: .ended)
        case let .twoFinger(gesture) where gesture.mode == .pinch:
            Injector.magnify(0, at: gesture.startCenter, phase: .ended)
        default:
            break
        }
        stopMomentum()
        pendingReturn?.cancel()
        pendingReturn = nil
        home = nil
        state = .idle
    }

    private func finish(remaining touches: [Touch]) {
        guard touches.isEmpty else {
            state = .ignoring
            return
        }
        state = .idle
        // With momentum running, the pointer goes back once it has settled.
        if momentum == nil { scheduleReturn() }
    }

    // MARK: One finger

    private func beginPress(_ touch: Touch, now: TimeInterval) {
        Injector.mouse(.mouseMoved, at: touch.point)
        state = .pressing(id: touch.id, start: touch.point, last: touch.point, since: now)

        // Press once the grace period runs out, even if the panel stays silent while the finger rests.
        let id = touch.id
        let timer = DispatchWorkItem { [weak self] in
            guard let self, case let .pressing(pressing, start, last, _) = self.state, pressing == id else { return }
            self.pressAndDrag(id: id, start: start, to: last, now: ProcessInfo.processInfo.systemUptime)
        }
        pressTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + tuning.secondFingerGrace, execute: timer)
    }

    private func cancelPressTimer() {
        pressTimer?.cancel()
        pressTimer = nil
    }

    private func pressAndDrag(id: Int64, start: CGPoint, to point: CGPoint, now: TimeInterval) {
        cancelPressTimer()
        let clicks = press(at: start, now: now)
        if point != start { Injector.mouse(.leftMouseDragged, at: point, clicks: clicks) }
        state = .down(id: id, last: point, clicks: clicks)
    }

    /// Presses the left button, counting consecutive presses for double/triple clicks.
    private func press(at point: CGPoint, now: TimeInterval) -> Int64 {
        var clicks: Int64 = 1
        if let last = lastPress, now - last.time < tuning.doubleClickInterval, distance(point, last.point) < tuning.slop * 2 {
            clicks = last.clicks + 1
        }
        lastPress = (point, now, clicks)
        Injector.mouse(.leftMouseDown, at: point, clicks: clicks)
        trace("press x\(clicks)")
        return clicks
    }

    // MARK: Two fingers

    private func beginTwoFinger(_ touches: [Touch], now: TimeInterval) {
        let c = centroid(touches), s = spread(touches)
        Injector.mouse(.mouseMoved, at: c)
        state = .twoFinger(TwoFinger(ids: touches.map(\.id), center: c, spread: s, baseSpread: s, startCenter: c, since: now))
    }

    private func moveTwoFinger(_ g: inout TwoFinger, _ touches: [Touch], now: TimeInterval) {
        let c = centroid(touches), s = spread(touches)

        // A finger landed, lifted or was replaced: the centroid and spread jump,
        // so rebase instead of scrolling or zooming by the jump.
        let ids = touches.map(\.id)
        if ids != g.ids {
            g.ids = ids
            g.center = c
            g.spread = s
            g.baseSpread = s
            return
        }

        g.travel.x += c.x - g.center.x
        g.travel.y += c.y - g.center.y

        if g.mode == .undecided {
            let travel = hypot(g.travel.x, g.travel.y)
            let spreadChange = touches.count >= 2 ? abs(s - g.baseSpread) : 0
            if spreadChange > tuning.pinchSlop, spreadChange > travel {
                g.mode = .pinch
                g.spread = g.baseSpread
                Injector.magnify(0, at: g.startCenter, phase: .began)
                trace("pinch")
            } else if travel > tuning.scrollSlop {
                g.mode = .scroll
                Injector.scroll(dx: 0, dy: 0, phase: .began)
                trace("scroll")
            } else {
                g.center = c
                return
            }
        }

        switch g.mode {
        case .scroll:
            let delta = CGPoint(x: c.x - g.center.x, y: c.y - g.center.y)
            Injector.scroll(dx: delta.x, dy: delta.y, phase: .changed)
            g.samples.append((now, delta))
            g.samples.removeAll { now - $0.time > tuning.velocityWindow }
        case .pinch where touches.count >= 2 && g.spread > 0:
            Injector.magnify(s / g.spread - 1, at: g.startCenter, phase: .changed)
            g.spread = s
        default:
            break
        }
        g.center = c
    }

    private func endTwoFinger(_ g: TwoFinger, now: TimeInterval) {
        switch g.mode {
        case .scroll:
            Injector.scroll(dx: 0, dy: 0, phase: .ended)
            startMomentum(g, now: now)
        case .pinch:
            Injector.magnify(0, at: g.startCenter, phase: .ended)
        case .undecided where now - g.since < tuning.twoFingerTapTime:
            Injector.click(at: g.startCenter, button: .right)
            trace("right click (two-finger tap)")
        case .undecided:
            break
        }
    }

    // MARK: Momentum

    private func startMomentum(_ g: TwoFinger, now: TimeInterval) {
        // Only movement just before the lift counts; a pause before lifting means no fling.
        let recent = g.samples.filter { now - $0.time <= tuning.velocityWindow }
        guard let first = recent.first else { return }
        let span = max(now - first.time, 1.0 / 120)
        let total = recent.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.delta.x, y: $0.y + $1.delta.y) }
        let velocity = CGPoint(x: total.x / span, y: total.y / span)
        guard hypot(velocity.x, velocity.y) > tuning.momentumMinSpeed else { return }

        Injector.scroll(dx: 0, dy: 0, phase: .momentumBegan)
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.stepMomentum() }
        RunLoop.main.add(timer, forMode: .common)
        momentum = (timer, velocity, g.startCenter, ProcessInfo.processInfo.systemUptime)
    }

    private func stepMomentum() {
        guard var m = momentum else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = now - m.last
        let decay = exp(-tuning.momentumFriction * dt)
        m.velocity = CGPoint(x: m.velocity.x * decay, y: m.velocity.y * decay)
        m.last = now
        momentum = m
        // The pointer moved (trackpad or mouse took over): stop, as a trackpad does on touch.
        if distance(Injector.cursor, m.point) > tuning.takeoverDistance {
            stopMomentum()
            home = nil // the user is steering the pointer now
            return
        }
        if hypot(m.velocity.x, m.velocity.y) < tuning.momentumMinSpeed / 3 {
            stopMomentum()
            scheduleReturn()
            return
        }
        Injector.scroll(dx: m.velocity.x * dt, dy: m.velocity.y * dt, phase: .momentum)
    }

    private func stopMomentum() {
        guard let m = momentum else { return }
        m.timer.invalidate()
        momentum = nil
        Injector.scroll(dx: 0, dy: 0, phase: .momentumEnded)
    }

    // MARK: Pointer return

    private func touchBegan() {
        // A quick follow-up touch (double tap, another flick) keeps the original home.
        let carried = pendingReturn != nil || momentum != nil ? home : nil
        pendingReturn?.cancel()
        pendingReturn = nil
        stopMomentum()
        if let carried {
            home = carried
            return
        }
        let cursor = Injector.cursor
        home = returnCursor && touchBounds.map { !$0.contains(cursor) } == true ? cursor : nil
    }

    private func scheduleReturn() {
        guard let home else { return }
        let left = Injector.cursor
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReturn = nil
            self.home = nil
            // Someone moved the mouse in the meantime: leave the pointer with them.
            if distance(Injector.cursor, left) > self.tuning.takeoverDistance {
                self.trace("pointer return skipped")
                return
            }
            Injector.mouse(.mouseMoved, at: home)
            self.trace("pointer returned")
        }
        pendingReturn = item
        DispatchQueue.main.asyncAfter(deadline: .now() + tuning.returnDelay, execute: item)
    }

    private func trace(_ message: String) {
        if verbose { log(message) }
    }
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    hypot(a.x - b.x, a.y - b.y)
}

private func centroid(_ touches: [Touch]) -> CGPoint {
    let pair = touches.prefix(2).map(\.point)
    return CGPoint(x: pair.map(\.x).reduce(0, +) / Double(pair.count), y: pair.map(\.y).reduce(0, +) / Double(pair.count))
}

private func spread(_ touches: [Touch]) -> Double {
    touches.count < 2 ? 0 : distance(touches[0].point, touches[1].point)
}
