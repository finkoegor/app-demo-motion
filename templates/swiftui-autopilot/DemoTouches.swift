#if DEBUG
import UIKit

/// Records every finger that lands in the app, for a run driven from outside by a UI
/// test, where the buttons are pressed for real and show it. Launched with
/// `-DemoTouches`, it writes the same timeline as the autopilot, `demo-taps.json` in the
/// temporary folder, after each touch. Call `DemoTouches.start()` in the app's `init`.
@MainActor
enum DemoTouches {
    private static var startedAt = Date()
    private static var startUptime = ProcessInfo.processInfo.systemUptime
    private static var taps: [DemoTap] = []
    private static var observer: NSObjectProtocol?

    static func start() {
        guard ProcessInfo.processInfo.arguments.contains("-DemoTouches"), observer == nil else { return }
        startedAt = Date()
        startUptime = ProcessInfo.processInfo.systemUptime
        observer = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? UIWindow else { return }
            MainActor.assumeIsolated { watch(window) }
        }
    }

    private static func watch(_ window: UIWindow) {
        guard !(window.gestureRecognizers ?? []).contains(where: { $0 is DemoTouchRecorder }) else { return }
        let recorder = DemoTouchRecorder(target: nil, action: nil)
        recorder.onTouchDown = { point, timestamp in
            taps.append(DemoTap(target: .touch, time: timestamp - startUptime, x: Double(point.x), y: Double(point.y)))
            write()
        }
        window.addGestureRecognizer(recorder)
    }

    private static func write() {
        let timeline = DemoTimeline(started: startedAt.timeIntervalSince1970, taps: taps)
        guard let data = try? JSONEncoder().encode(timeline) else { return }
        try? data.write(to: DemoAutopilot.timelineURL, options: .atomic)
    }
}
#endif
