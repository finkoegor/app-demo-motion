#if DEBUG
import SwiftUI

/// Tells the demo autopilot where a control is and whether it can be pressed, and runs
/// the control's action when the autopilot presses it. The target may change while the
/// view stays, as a footer button that reads Continue on one step and Save on the next.
struct DemoTargetModifier: ViewModifier {
    let target: DemoTarget
    let isEnabled: Bool
    let anchor: UnitPoint
    /// For a control the system draws, whose frame SwiftUI doesn't know.
    var locate: (() -> CGRect?)? = nil
    let action: () -> Void

    @State private var frame: CGRect?
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        if let demo = DemoAutopilot.shared {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    guard locate == nil else { return }
                    self.frame = frame
                    demo.place(target, at: frame, anchor: anchor, owner: owner)
                }
                .onAppear {
                    if let locate { demo.locate(target, anchor: anchor, with: locate) }
                }
                .onChange(of: isEnabled, initial: true) { _, isEnabled in
                    demo.setEnabled(target, isEnabled, owner: owner)
                }
                .onChange(of: target) { old, new in
                    demo.remove(old, owner: owner)
                    if let frame { demo.place(new, at: frame, anchor: anchor, owner: owner) }
                    demo.setEnabled(new, isEnabled, owner: owner)
                }
                .onChange(of: demo.pressing) { _, pressing in
                    guard pressing == target else { return }
                    demo.didPress(target)
                    action()
                }
                .onDisappear { demo.remove(target, owner: owner) }
        } else {
            content
        }
    }
}
#endif
