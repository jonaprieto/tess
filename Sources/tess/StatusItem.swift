import AppKit
import Layout

/// Menu bar item: a live miniature of the monitors as they are arranged, with their columns
/// and windows. The focused window and the active monitor take the mode's color.
final class StatusItem: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let tiler: Tiler
    var waitingForAccess = false

    init(_ tiler: Tiler) {
        self.tiler = tiler
        super.init()
        refresh()
    }

    func refresh() {
        refreshIcon()
        refreshMenu()
    }

    /// Cheap enough to run on every layout or focus change.
    func refreshIcon() {
        guard let button = item.button else { return }
        button.image = minimap()
        button.title = ""
        button.toolTip = "tess: \(tiler.paused ? "paused" : tiler.mode)"
    }

    private var color: NSColor {
        if waitingForAccess { return .systemRed }
        if tiler.paused { return .systemGray }
        switch tiler.mode {
        case "main": return .controlAccentColor
        case "resize": return .systemOrange
        case "service": return .systemPurple
        case "wm": return .systemGreen
        default: return .systemTeal
        }
    }

    private func minimap() -> NSImage {
        let world = tiler.world
        let color = color
        let monitors = world.monitors
        let paused = tiler.paused
        guard let bounds = monitors.map(\.frame).reduce(nil, { $0?.union($1) ?? $1 }), bounds.width > 0 else {
            return NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "tess")!
        }
        let scale = min(16 / bounds.height, 64 / bounds.width)
        let frames = world.frames(inner: 0, outer: 0)
        func mini(_ r: CGRect) -> CGRect {
            CGRect(x: 1 + (r.minX - bounds.minX) * scale, y: 1 + (r.minY - bounds.minY) * scale,
                   width: r.width * scale, height: r.height * scale)
        }
        let size = NSSize(width: bounds.width * scale + 2, height: bounds.height * scale + 2)
        let image = NSImage(size: size, flipped: true) { _ in
            let dim = NSColor.labelColor.withAlphaComponent(paused ? 0.25 : 0.4)
            for (m, mon) in monitors.enumerated() {
                let box = mini(mon.frame).insetBy(dx: 1, dy: 0.5)
                let outline = NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5)
                outline.lineWidth = 1
                (m == world.activeMonitor ? color : dim).setStroke()
                outline.stroke()
                // Unfocused first, so in an accordion the focused window is drawn on top.
                for id in mon.windows.filter({ $0 != world.focused }) + mon.windows.filter({ $0 == world.focused }) {
                    guard let f = frames[id] else { continue }
                    let r = mini(f).intersection(box).insetBy(dx: 1.25, dy: 1.25)
                    guard r.width > 0.5, r.height > 0.5 else { continue }
                    (id == world.focused ? color : dim).setFill()
                    NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "tess"
        return image
    }

    private func refreshMenu() {
        let menu = NSMenu()
        if waitingForAccess {
            menu.addItem(action("Grant Accessibility access…", #selector(openAccessibility)))
            menu.addItem(.separator())
        }
        if let error = tiler.configError {
            let e = NSMenuItem(title: "Config: \(error)", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
            menu.addItem(.separator())
        }
        menu.addItem(action("Rescue windows", #selector(rescue)))
        menu.addItem(action("Re-tile", #selector(retile)))
        menu.addItem(action(tiler.paused ? "Resume tiling" : "Pause tiling", #selector(pause)))
        menu.addItem(action("Reload config", #selector(reload)))
        menu.addItem(action("Open config", #selector(openConfig)))
        menu.addItem(.separator())
        menu.addItem(action("Quit tess", #selector(quit)))
        item.menu = menu
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func rescue() { tiler.menuRescue() }
    @objc private func retile() { tiler.menuRetile() }
    @objc private func pause() { tiler.menuPause() }
    @objc private func reload() { tiler.menuReload() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Opens the config in the default editor, writing the defaults first if there is none.
    @objc private func openConfig() {
        let url = Tiler.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Config.defaultJSON.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
}
