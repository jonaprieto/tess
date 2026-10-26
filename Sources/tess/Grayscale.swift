import AppKit

/// What is on screen in black and white at 80%, but for a hole where the focused window is:
/// one click-through panel per screen, just above normal windows and below tess's labels.
final class Grayscale {
    private var panels: [(panel: NSPanel, hole: CGRect?)] = []
    private let available = Grayscale.backdrop() != nil

    /// Each screen's frame and the focused window's frame when it is on that screen.
    func show(_ screens: [(frame: CGRect, hole: CGRect?)]) {
        guard available else { return }
        while panels.count < screens.count, let backdrop = Self.backdrop() {
            let p = Panels.overlay(level: NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1))
            let host = NSView()
            host.wantsLayer = true
            backdrop.opacity = 0.8
            host.layer?.addSublayer(backdrop)
            p.contentView = host
            panels.append((p, nil))
        }
        for n in panels.indices {
            let p = panels[n].panel
            guard let screen = screens[safe: n] else {
                p.orderOut(nil)
                continue
            }
            let frame = Screens.flip(screen.frame)
            guard p.frame != frame || panels[n].hole != screen.hole || !p.isVisible else { continue }
            p.setFrame(frame, display: false)
            panels[n].hole = screen.hole
            guard let host = p.contentView else { continue }
            host.layer?.sublayers?.forEach { $0.frame = host.bounds }
            // The whole screen minus the focused window, with its rounded corners.
            let path = CGMutablePath()
            path.addRect(host.bounds)
            if let hole = screen.hole {
                let local = Screens.flip(hole).offsetBy(dx: -frame.minX, dy: -frame.minY)
                path.addRoundedRect(in: local, cornerWidth: 12, cornerHeight: 12)
            }
            let mask = CAShapeLayer()
            mask.frame = host.bounds
            mask.path = path
            mask.fillRule = .evenOdd
            host.layer?.mask = mask
            p.orderFrontRegardless()
        }
    }

    func hide() {
        for n in panels.indices where panels[n].panel.isVisible { panels[n].panel.orderOut(nil) }
    }

    /// ponytail: QuartzCore's private CABackdropLayer (what macOS's blur views draw with) with a
    /// colorSaturate filter at 0: the window server shows what is behind in black and white, no
    /// capture and no permission. nil if either class goes away, and nothing is grayed.
    static func backdrop() -> CALayer? {
        guard let layerType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let filterType = NSClassFromString("CAFilter") as? NSObject.Type,
              let filter = filterType.perform(NSSelectorFromString("filterWithType:"), with: "colorSaturate")?
                  .takeUnretainedValue() as? NSObject
        else { return nil }
        filter.setValue(0, forKey: "inputAmount")
        let layer = layerType.init()
        layer.filters = [filter]
        // Samples other apps' windows, not only this one's (CALayer takes any key, so this
        // cannot throw).
        layer.setValue(true, forKey: "windowServerAware")
        return layer
    }
}

/// Black and white everywhere but the focused window (overlay.gray_others) while its app is in
/// front; not in Zen (its veil has the other screens), nor paused, nor with another app or one
/// of tess's own windows in front.
extension Tiler {
    func refreshGray() {
        guard config.grayOthers, !paused, !starting, zen == nil, let f = world.focused, let info = infos[f],
              NSWorkspace.shared.frontmostApplication?.processIdentifier == info.pid
        else { return grayscale.hide() }
        grayscale.show(world.monitors.map { m in (m.frame, m.frame.intersects(info.frame) ? info.frame : nil) })
    }
}
