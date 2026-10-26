import AppKit

enum Panels {
    /// A borderless, click-through panel on every Space that never takes focus.
    static func overlay(level: NSWindow.Level) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = level
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return p
    }

    /// `view` on the system glass, with rounded corners.
    static func glass(_ view: NSView, radius: CGFloat) -> NSGlassEffectView {
        let g = NSGlassEffectView()
        g.cornerRadius = radius
        g.contentView = view
        return g
    }
}
