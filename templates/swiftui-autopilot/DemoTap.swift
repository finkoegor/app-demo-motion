#if DEBUG
import Foundation

/// One press of a demo run, for the editing script to draw: seconds since the run
/// began and the control's center in screen points. A swipe also carries where the
/// finger lifts and how long it moved, eased in and out.
struct DemoTap: Codable {
    let target: DemoTarget
    let time: TimeInterval
    let x: Double
    let y: Double
    var gesture: String?
    var x2: Double?
    var y2: Double?
    var duration: TimeInterval?
}
#endif
