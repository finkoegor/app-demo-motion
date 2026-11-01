#if DEBUG
/// A control the demo autopilot presses. Name every control your script touches and
/// mark the control's view with `.demoTarget(.name) { action }`.
enum DemoTarget: String, Codable {
    case add
    /// A control that is swiped to a value rather than tapped (see `DemoSwipe`).
    case value
    case save
}
#endif
