import AppKit
import Layout

/// Window letters, screen numbers and jump mode.
extension Tiler {
    // MARK: Labels and jump mode

    // MARK: tess tree

    // MARK: Labels and jump mode

    /// Visible windows in screen, lane and stack order, then floating ones.
    var labeledWindows: [WindowID] {
        (world.tiled + world.floating.sorted()).filter { infos[$0] != nil && !offSpace.contains($0) }
    }


    /// Borders and letters on every window, numbers on every screen (overlay.window_labels).
    func refreshDecorations() {
        labels = stableLabels(labels, windows: labeledWindows, alphabet: labelAlphabet)
        let show = config.windowLabels == .always || (config.windowLabels == .jump && jumping)
        guard show, !paused, !starting else {
            if !drawn.isEmpty { decorations.hide() }
            drawn = []
            return
        }
        let windows = labeledWindows.compactMap { id -> Decorations.Window? in
            guard let f = infos[id]?.frame else { return nil }
            // Under tess fullscreen only the fullscreen window is shown.
            if let p = world.locate(id), let fs = world.monitors[p.m].fullscreen, fs != id { return nil }
            return Decorations.Window(frame: f, label: labels[id], focused: id == world.focused)
        }
        let screens = world.monitors.map(\.frame)
        let signature = screens.map { "\($0)" } + windows.map { "\($0.frame)\($0.label.map(String.init) ?? "")\($0.focused)" }
            + ["\(jumping)"]
        guard signature != drawn else { return }
        drawn = signature
        decorations.update(screens: screens, windows: windows, jumping: jumping)
    }


    /// Every window's letter becomes a key (shift swaps with it), every screen's number too
    /// (shift moves there); one use, or esc, goes back to the mode jump started from (main from
    /// a one-shot mode).
    func startJump() {
        guard !jumping else { return }
        jumpReturn = returnMode
        mode = "jump"
        Events.record("mode", ["mode": "jump"])
        let (keys, exits) = jumpKeys(labels: labels, windows: labeledWindows, screens: world.monitors.count,
                                     back: [.mode(jumpReturn)])
        let failed = hotkeys.register(keys)
        if !failed.isEmpty { Log.write("jump: could not register \(failed)") }
        drawn = []
        refreshDecorations()
        // A cheat sheet like any mode's, for as long as jump mode lasts.
        let n = max(world.monitors.count, 1)
        overlay.showSheet("Jump", rows: [("A–Z", "Go to that window"), ("⇧ A–Z", "Swap it with the focused one"),
                                         ("1–\(n)", "Go to that screen"), ("⇧ 1–\(n)", "Move the focused window there")],
                          back: exits.map(\.symbol), on: modeScreens)
        onChange()
    }
}
