import AppKit
import Layout

/// Menu bar item: a grid in main mode, the mode's initial otherwise, a pause sign when paused.
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
        guard let button = item.button else { return }
        if tiler.paused || waitingForAccess {
            button.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: "tess paused")
            button.title = ""
        } else if tiler.mode == "main" {
            button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "tess")
            button.title = ""
        } else {
            button.image = nil
            button.title = String(tiler.mode.prefix(1)).uppercased()
        }
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
