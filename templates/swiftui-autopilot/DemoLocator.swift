#if DEBUG
import UIKit

/// Finds controls the system draws itself, which SwiftUI can't measure, in screen points.
enum DemoLocator {

    /// The tab bar button at `index`, counted from the left. The buttons carry no labels of
    /// their own, so they are told apart by place; the bar draws each one twice, plain and
    /// selected, at the same spot.
    static func frameOfTab(at index: Int) -> CGRect? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let bar = windows.lazy.compactMap({ first(UITabBar.self, in: $0) }).first else { return nil }
        let buttons = descendants(of: bar)
            .filter { String(describing: type(of: $0)) == "_UITabButton" && !$0.isHidden }
            .map { $0.convert($0.bounds, to: nil) }
            .reduce(into: [CGRect]()) { frames, frame in
                if !frames.contains(where: { abs($0.minX - frame.minX) < 1 }) { frames.append(frame) }
            }
            .sorted { $0.minX < $1.minX }
        return buttons.indices.contains(index) ? buttons[index] : nil
    }

    /// The leftmost button of the navigation bar on top: the back button of a pushed
    /// screen or the first button of a root one. A bar under a sheet or under another
    /// screen doesn't count, because a tap there wouldn't reach it.
    static func frameOfLeadingBarButton() -> CGRect? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .filter { !$0.isHidden }
            .sorted { $0.windowLevel > $1.windowLevel }
        for window in windows {
            let controls = descendants(of: window)
                .compactMap { $0 as? UINavigationBar }
                .flatMap(descendants(of:))
                .filter { $0 is UIControl && !$0.isHidden && $0.alpha > 0.01 && $0.bounds.width > 20 }
                .map { ($0, $0.convert($0.bounds, to: window)) }
                .sorted { $0.1.minX < $1.1.minX }
            for (control, frame) in controls {
                let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
                if let hit, hit.isDescendant(of: control) { return frame }
            }
        }
        return nil
    }

    /// The rightmost button of the navigation bar a tap would reach: bars of other tabs
    /// and bars under a sheet don't count.
    static func frameOfTrailingBarButton() -> CGRect? {
        trailingBarButton().map { $0.convert($0.bounds, to: nil) }
    }

    /// Opens the menu of the rightmost bar button, a SwiftUI `Menu` in the toolbar, as a
    /// tap would. A menu has no action to call, so this goes through the button's menu
    /// interaction and a private UIKit method.
    static func presentMenuOfTrailingBarButton() {
        guard let button = trailingBarButton(),
              let interaction = ([button] + descendants(of: button))
                .lazy
                .compactMap({ $0.interactions.first { $0 is UIContextMenuInteraction } as? UIContextMenuInteraction })
                .first,
              let view = interaction.view
        else { return }
        let present = NSSelectorFromString("_presentMenuAtLocation:")
        guard interaction.responds(to: present) else { return }
        typealias Present = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        let call = unsafeBitCast(interaction.method(for: present), to: Present.self)
        call(interaction, present, CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        openMenu = interaction
    }

    /// Where a row of the open menu is, found by its title.
    static func frameOfMenuItem(titled title: String) -> CGRect? {
        let label = windows()
            .flatMap(descendants(of:))
            .compactMap { $0 as? UILabel }
            .first { $0.text == title && $0.window != nil && !$0.isHidden && $0.alpha > 0.01 }
        guard let label else { return nil }
        var row: UIView = label
        while let parent = row.superview, parent.bounds.height < 64 {
            row = parent
        }
        return row.convert(row.bounds, to: nil)
    }

    /// Closes the menu opened above, as picking one of its rows does; the row's action
    /// is the target's own.
    static func dismissMenu() {
        openMenu?.dismissMenu()
        openMenu = nil
    }

    private static weak var openMenu: UIContextMenuInteraction?

    private static func trailingBarButton() -> UIView? {
        for window in windows().filter({ !$0.isHidden }).sorted(by: { $0.windowLevel > $1.windowLevel }) {
            let controls = descendants(of: window)
                .compactMap { $0 as? UINavigationBar }
                .flatMap(descendants(of:))
                .filter { $0 is UIControl && !$0.isHidden && $0.alpha > 0.01 && $0.bounds.width > 20 }
                .sorted { $0.convert($0.bounds, to: window).maxX > $1.convert($1.bounds, to: window).maxX }
            for control in controls {
                let frame = control.convert(control.bounds, to: window)
                if let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil), hit.isDescendant(of: control) {
                    return control
                }
            }
        }
        return nil
    }

    private static func windows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
    }

    private static func first<View: UIView>(_ type: View.Type, in view: UIView) -> View? {
        if let match = view as? View { return match }
        for subview in view.subviews {
            if let match = first(type, in: subview) { return match }
        }
        return nil
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }
}
#endif
