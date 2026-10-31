import CoreGraphics
import Foundation

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
    }

    private enum TwoFingerMode { case undecided, scroll, pinch }

    private struct TwoFinger {
        var mode = TwoFingerMode.undecided
        var count: Int
        var center: CGPoint
        var spread: Double
        let startCenter: CGPoint
        let startSpread: Double
        let since: TimeInterval
        /// Centroid travel since touch-down, excluding jumps from fingers landing or lifting.
        var travel = CGPoint.zero
        var samples: [(time: TimeInterval, delta: CGPoint)] = []
    }

    private enum State {
        case idle
        case pressing(start: CGPoint, since: TimeInterval)
        case down(last: CGPoint, clicks: Int64)
        case twoFinger(TwoFinger)
    }

    private var state = State.idle
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

    func handle(_ points: [CGPoint], now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        switch (state, points.count) {
        case (.idle, 0):
            break

        case (.idle, 1):
            touchBegan()
            Injector.mouse(.mouseMoved, at: points[0])
            state = .pressing(start: points[0], since: now)

        case (.idle, _):
            touchBegan()
            beginTwoFinger(points, now: now)

        case (.pressing, 2...):
            beginTwoFinger(points, now: now)

        case let (.pressing(start, since), 1):
            if now - since > tuning.secondFingerGrace || distance(points[0], start) > tuning.slop * 3 {
                let clicks = press(at: start, now: now)
                if points[0] != start { Injector.mouse(.leftMouseDragged, at: points[0], clicks: clicks) }
                state = .down(last: points[0], clicks: clicks)
            }

        case let (.pressing(start, _), 0):
            let clicks = press(at: start, now: now)
            Injector.mouse(.leftMouseUp, at: start, clicks: clicks)
            gestureEnded()

        case let (.down(last, clicks), 1...):
            // Extra fingers during a drag are ignored; the first contact keeps driving the pointer.
            if points[0] != last { Injector.mouse(.leftMouseDragged, at: points[0], clicks: clicks) }
            state = .down(last: points[0], clicks: clicks)

        case let (.down(last, clicks), 0):
            Injector.mouse(.leftMouseUp, at: last, clicks: clicks)
            gestureEnded()

        case (.twoFinger(var gesture), 1...):
            moveTwoFinger(&gesture, points, now: now)
            state = .twoFinger(gesture)

        case let (.twoFinger(gesture), 0):
            endTwoFinger(gesture, now: now)
            gestureEnded()

        default:
            break
        }
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

    private func gestureEnded() {
        state = .idle
        // With momentum running, the pointer goes back once it has settled.
        if momentum == nil { scheduleReturn() }
    }

    private func scheduleReturn() {
        guard let home else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.pendingReturn = nil
            self?.home = nil
            Injector.mouse(.mouseMoved, at: home)
            self?.trace("pointer returned")
        }
        pendingReturn = item
        DispatchQueue.main.asyncAfter(deadline: .now() + tuning.returnDelay, execute: item)
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

    private func beginTwoFinger(_ points: [CGPoint], now: TimeInterval) {
        let c = centroid(points), s = spread(points)
        Injector.mouse(.mouseMoved, at: c)
        state = .twoFinger(TwoFinger(count: points.count, center: c, spread: s, startCenter: c, startSpread: s, since: now))
    }

    private func moveTwoFinger(_ g: inout TwoFinger, _ points: [CGPoint], now: TimeInterval) {
        let c = centroid(points), s = spread(points)

        // A finger landed or lifted: the centroid jumps, so rebase instead of scrolling by the jump.
        if points.count != g.count {
            g.count = points.count
            g.center = c
            g.spread = s
            return
        }

        g.travel.x += c.x - g.center.x
        g.travel.y += c.y - g.center.y

        if g.mode == .undecided {
            let travel = hypot(g.travel.x, g.travel.y)
            let spreadChange = points.count >= 2 ? abs(s - g.startSpread) : 0
            if spreadChange > tuning.pinchSlop, spreadChange > travel {
                g.mode = .pinch
                g.spread = g.startSpread
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
        case .pinch where points.count >= 2 && g.spread > 0:
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
        guard let first = g.samples.first else { return }
        let span = max(now - first.time, 1.0 / 120)
        let total = g.samples.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.delta.x, y: $0.y + $1.delta.y) }
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
        if distance(Injector.cursor, m.point) > 2 {
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

    private func trace(_ message: String) {
        if verbose { log(message) }
    }
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    hypot(a.x - b.x, a.y - b.y)
}

private func centroid(_ points: [CGPoint]) -> CGPoint {
    let pair = points.prefix(2)
    return CGPoint(x: pair.map(\.x).reduce(0, +) / Double(pair.count), y: pair.map(\.y).reduce(0, +) / Double(pair.count))
}

private func spread(_ points: [CGPoint]) -> Double {
    points.count < 2 ? 0 : distance(points[0], points[1])
}
