#if DEBUG
import Foundation
import Observation
import QuartzCore
import SwiftUI

/// Plays a scripted run through the app for promo recordings. A debug build launched
/// with `-Demo` presses controls on a timer through their own actions, so the pacing
/// is exact and every animation is the real one, and writes where and when each press
/// landed to `demo-taps.json` in the app's temporary folder.
///
/// Start it once the root view is up: `.task { await DemoAutopilot.shared?.run() }`.
@MainActor @Observable
final class DemoAutopilot {

    static let shared: DemoAutopilot? = ProcessInfo.processInfo.arguments.contains("-Demo") ? DemoAutopilot() : nil

    /// Anything the script needs from the launch arguments, as `-DemoLink <url>`.
    static func argument(_ name: String) -> String? {
        UserDefaults.standard.string(forKey: "Demo" + name)
    }

    /// The control to press now; its view runs the action and reports back.
    private(set) var pressing: DemoTarget?
    /// The swipe the control being pressed should play, when the press is a swipe.
    private(set) var swiping: DemoSwipe?

    /// Where each control's press lands, in screen points.
    @ObservationIgnored private var points: [DemoTarget: CGPoint] = [:]
    @ObservationIgnored private var frames: [DemoTarget: CGRect] = [:]
    /// The view each target was last placed by, so a view leaving doesn't take the target
    /// away from the one that took its place (a button of the same name on the next screen).
    @ObservationIgnored private var owners: [DemoTarget: UUID] = [:]
    @ObservationIgnored private var locators: [DemoTarget: (anchor: UnitPoint, frame: () -> CGRect?)] = [:]
    @ObservationIgnored private var enabled: Set<DemoTarget> = []
    @ObservationIgnored private var taps: [DemoTap] = []
    @ObservationIgnored private var start: CFTimeInterval = 0
    @ObservationIgnored private var startedAt = Date()

    static let timelineURL = FileManager.default.temporaryDirectory.appending(path: "demo-taps.json")

    /// The scenario. `press` waits until the control is on screen and enabled, so a
    /// step that depends on loading needs no guesswork; `after` holds it a while longer.
    /// `swipe` drags a control (a slider, a wheel, a carousel) to a value.
    func run() async {
        start = CACurrentMediaTime()
        startedAt = Date()
        // Let the first screen settle before the clip begins.
        await pause(2.5)
        await press(.add)
        await pause(1.2)
        await swipe(.value, at: UnitPoint(x: 0.3, y: 0.5), to: 8, over: 1.2)
        await pause(0.8)
        await press(.save, after: 0.6)
        await pause(2.0)
        writeTimeline()
    }

    func place(_ target: DemoTarget, at frame: CGRect, anchor: UnitPoint = .center, owner: UUID? = nil) {
        points[target] = CGPoint(x: frame.minX + frame.width * anchor.x, y: frame.minY + frame.height * anchor.y)
        frames[target] = frame
        if let owner { owners[target] = owner }
    }

    /// Where the finger of the swipe now playing lifts, `distance` points to the right of
    /// where it landed (to the left when below zero). The swiped control calls it once it
    /// knows how far its value is.
    func swiped(by distance: CGFloat) {
        guard let index = taps.indices.last, taps[index].gesture == "swipe" else { return }
        taps[index].x2 = taps[index].x + distance
        taps[index].y2 = taps[index].y
    }

    func setEnabled(_ target: DemoTarget, _ isEnabled: Bool, owner: UUID? = nil) {
        if let owner { owners[target] = owner }
        if isEnabled { enabled.insert(target) } else { enabled.remove(target) }
    }

    func locate(_ target: DemoTarget, anchor: UnitPoint, with frame: @escaping () -> CGRect?) {
        locators[target] = (anchor, frame)
        enabled.insert(target)
    }

    func remove(_ target: DemoTarget, owner: UUID? = nil) {
        if let owner, let current = owners[target], current != owner { return }
        owners[target] = nil
        points[target] = nil
        frames[target] = nil
        enabled.remove(target)
    }

    func didPress(_ target: DemoTarget) {
        if pressing == target { pressing = nil }
    }

    /// A swipe on `target`, the finger landing at `anchor` of it, to `value`; waits for
    /// the finger to lift. The control plays it from `swiping` (see `DemoSwipe`).
    private func swipe(_ target: DemoTarget, at anchor: UnitPoint, to value: Int, over duration: TimeInterval) async {
        while frames[target] == nil || !enabled.contains(target) {
            await pause(0.05)
        }
        guard let frame = frames[target] else { return }
        let point = CGPoint(x: frame.minX + frame.width * anchor.x, y: frame.minY + frame.height * anchor.y)
        var tap = DemoTap(target: target, time: CACurrentMediaTime() - start, x: point.x, y: point.y)
        tap.gesture = "swipe"
        tap.duration = duration
        taps.append(tap)
        swiping = DemoSwipe(value: value, duration: duration)
        pressing = target
        await pause(duration)
        swiping = nil
    }

    private func press(_ target: DemoTarget, after delay: TimeInterval = 0) async {
        while points[target] == nil || !enabled.contains(target) {
            if let locator = locators[target], let frame = locator.frame() {
                place(target, at: frame, anchor: locator.anchor)
                continue
            }
            await pause(0.05)
        }
        await pause(delay)
        guard let point = points[target] else { return }
        taps.append(DemoTap(target: target, time: CACurrentMediaTime() - start, x: point.x, y: point.y))
        pressing = target
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func writeTimeline() {
        let timeline = DemoTimeline(started: startedAt.timeIntervalSince1970, taps: taps)
        guard let data = try? JSONEncoder().encode(timeline) else { return }
        try? data.write(to: Self.timelineURL)
    }
}
#endif
