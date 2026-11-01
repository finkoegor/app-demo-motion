#if DEBUG
import Foundation

/// A sideways swipe the autopilot asks a control to play: the value to swipe to and how
/// long the finger moves. The control works out how far that is, reports it with
/// `DemoAutopilot.swiped(by:)` and moves its value along `ease`, the curve the editing
/// script moves the ring on:
///
///     .demoTarget(.value) {
///         guard let demo = DemoAutopilot.shared, let swipe = demo.swiping else { return }
///         let from = position
///         let distance = (Double(swipe.value) - from) * pointsPerStep
///         demo.swiped(by: distance)
///         Task {
///             let began = Date.now
///             var progress = 0.0
///             while progress < 1 {
///                 progress = min(1, Date.now.timeIntervalSince(began) / swipe.duration)
///                 position = from + distance * DemoSwipe.ease(progress) / pointsPerStep
///                 try? await Task.sleep(for: .milliseconds(8))
///             }
///         }
///     }
///
/// A control that turns the other way (a wheel whose value falls as the finger goes
/// right) reports a distance of the opposite sign.
struct DemoSwipe: Equatable {
    let value: Int
    let duration: TimeInterval

    /// The finger's progress along the swipe, starting and ending at rest.
    static func ease(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
}
#endif
