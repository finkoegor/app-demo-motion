import ObjectiveC
import XCTest

/// Plays a promo flow with real touches, so every button shows its press the way a finger
/// makes it (the tab bar's glass lens, a highlighted button, a sinking card). The app,
/// launched with `-DemoTouches`, records where each finger landed for the rings. Runs only
/// with PROMO=1 (TEST_RUNNER_PROMO=1 for xcodebuild), so it never joins the test suite.
///
/// XCTest waits for the app to settle around every event, and asking an element for its
/// frame takes a second or more; both show as dead pauses in a clip. So the waits are
/// switched off, presses go to points read from one snapshot of each screen, and the
/// pauses alone set the pace, each long enough for its screen to finish moving.
final class PromoRun: XCTestCase {
    @MainActor
    func testPromo() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROMO"] == "1", "Only for promo recordings")
        let app = XCUIApplication()
        app.launchArguments = ["-DemoTouches"]
        app.launch()
        let tab = app.tabBars.buttons["Library"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        let tabPoint = tab.frame.center
        Self.skipWaitingForIdle()

        rest(2.0)
        press(tabPoint, in: app)
        rest(0.45)

        // One snapshot per screen, then a press every half second or so.
        let screen = try snapshot(of: app, showing: "Add")
        for title in ["First", "Second", "Third"] {
            press(try button(title, in: screen).center, in: app)
            rest(0.05)
        }
        rest(0.3)
        press(try button("Add", in: screen).center, in: app)
        // Never query the app right after a press: a snapshot of the accessibility tree
        // runs on the app's main thread and freezes the button's highlight and whatever
        // the press opens. Rest first, as long as the opening takes.
        rest(0.7)
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        rest(0.2)
        name.typeText("Video Testing")
        rest(0.15)
        name.typeText("\n")
        rest(1.5)
    }

    /// A finger's tap. A press held for a while (`press(forDuration:)`) comes up late once
    /// the idle waits are off, and a button stays lit twice as long.
    @MainActor
    private func press(_ point: CGPoint, in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x, dy: point.y))
            .tap()
    }

    /// The screen once something on it shows, read in one go.
    @MainActor
    private func snapshot(of app: XCUIApplication, showing label: String) throws -> XCUIElementSnapshot {
        var screen = try app.snapshot()
        for _ in 0..<10 where screen.first(where: { $0.label == label }) == nil {
            rest(0.1)
            screen = try app.snapshot()
        }
        return screen
    }

    @MainActor
    private func button(_ label: String, in screen: XCUIElementSnapshot) throws -> CGRect {
        try XCTUnwrap(screen.first { $0.elementType == .button && $0.label == label }, "No \(label) button").frame
    }

    private func rest(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// XCTest waits before and after every event until the app stops animating; telling
    /// it to skip those waits leaves the timing to the script. Private API, test only.
    private static func skipWaitingForIdle() {
        guard let process = NSClassFromString("XCUIApplicationProcess") else { return }
        for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
            guard let method = class_getInstanceMethod(process, NSSelectorFromString(name)) else { continue }
            let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
            method_setImplementation(method, imp_implementationWithBlock(skip))
        }
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension XCUIElementSnapshot {
    func first(where matches: (XCUIElementSnapshot) -> Bool) -> XCUIElementSnapshot? {
        if matches(self) {
            return self
        }
        for child in children {
            if let found = child.first(where: matches) {
                return found
            }
        }
        return nil
    }
}
