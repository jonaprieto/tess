import AppKit

enum Panels {
    /// Borders and highlights: the config's overlay.border_color, else the macOS accent color.
    nonisolated(unsafe) static var accent = NSColor.controlAccentColor
    nonisolated(unsafe) static var inactiveBorder = NSColor.labelColor.withAlphaComponent(0.22)
    nonisolated(unsafe) static var selection = NSColor.systemOrange

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
