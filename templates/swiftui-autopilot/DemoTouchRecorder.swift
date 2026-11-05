#if DEBUG
import UIKit

/// Watches a window for fingers going down and reports each one, without taking part in
/// the touch: it never recognizes, delays or cancels anything.
final class DemoTouchRecorder: UIGestureRecognizer {
    var onTouchDown: ((CGPoint, TimeInterval) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            onTouchDown?(touch.location(in: nil), touch.timestamp)
        }
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }
}
#endif
