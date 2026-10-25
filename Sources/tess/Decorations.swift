import AppKit
import Layout

/// Always-on labels: a thin border and a letter on every window, a number on every screen.
/// One click-through panel per screen, just above normal windows, redrawn after each layout
/// pass. In jump mode the letters grow, since they are then the keys.
final class Decorations {
    struct Window {
        var frame: CGRect
        var label: Character?
        var focused: Bool
    }

    private var panels: [NSPanel] = []

    func update(screens: [CGRect], windows: [Window], jumping: Bool) {
        while panels.count < screens.count { panels.append(Self.panel()) }
        while panels.count > screens.count { panels.removeLast().orderOut(nil) }
        for (n, screen) in screens.enumerated() {
            let p = panels[n]
            let view = (p.contentView as? DecorationView) ?? DecorationView()
            view.screen = screen
            view.number = n + 1
            view.jumping = jumping
            view.windows = windows.filter { screen.intersects($0.frame) }
            p.contentView = view
            p.setFrame(Screens.flip(screen), display: false)
            view.needsDisplay = true
            p.orderFrontRegardless()
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    private static func panel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above normal windows, below menus, the picker and tess's own toasts.
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return p
    }
}

final class DecorationView: NSView {
    var screen = CGRect.zero
    var number = 1
    var jumping = false
    var windows: [Decorations.Window] = []

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -screen.minX, dy: -screen.minY) }
        // Borders first, the focused one last so it is on top.
        for w in windows.sorted(by: { !$0.focused && $1.focused }) {
            let r = local(w.frame).insetBy(dx: -1, dy: -1)
            let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
            path.lineWidth = w.focused ? 3 : 1.5
            (w.focused ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.22)).setStroke()
            path.stroke()
        }
        // Letters centred on each window's top border; windows sharing a frame (an accordion)
        // get their letters side by side.
        var shared: [String: Int] = [:]
        let height: CGFloat = jumping ? 30 : 20
        for w in windows {
            guard let label = w.label else { continue }
            let r = local(w.frame)
            let key = "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))"
            let i = shared[key, default: 0]
            shared[key] = i + 1
            let width = height + 6
            let x = r.midX - width / 2 + CGFloat(i) * (width + 4)
            badge(String(label).uppercased(), NSRect(x: x, y: r.minY - height / 2, width: width, height: height),
                  strong: w.focused || jumping)
        }
        // The screen's number in its bottom-left corner (top-left would sit on a window's
        // close button).
        let side: CGFloat = jumping ? 34 : 22
        badge("\(number)", NSRect(x: 2, y: bounds.height - side - 2, width: side, height: side), strong: jumping, round: true)
    }

    private func badge(_ text: String, _ r: NSRect, strong: Bool, round: Bool = false) {
        let path = NSBezierPath(roundedRect: r, xRadius: round ? r.height / 2 : 6, yRadius: round ? r.height / 2 : 6)
        (strong ? NSColor.controlAccentColor : NSColor.windowBackgroundColor.withAlphaComponent(0.92)).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(strong ? 0 : 0.25).setStroke()
        path.lineWidth = 0.5
        path.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: r.height * 0.58, weight: .bold),
            .foregroundColor: strong ? NSColor.white : NSColor.labelColor,
        ]
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: attrs)
    }
}
