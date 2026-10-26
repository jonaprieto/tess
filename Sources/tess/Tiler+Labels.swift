import AppKit
import Layout

/// Window letters, tab letters, screen numbers and jump mode.
extension Tiler {
    // MARK: Labels and jump mode

    /// Visible windows in screen, lane and stack order, then floating ones.
    var labeledWindows: [WindowID] {
        (world.tiled + world.floating.sorted()).filter { infos[$0] != nil && !offSpace.contains($0) }
    }

    /// Letters are keys: in jump mode, and in tess mode on the letters it leaves free.
    var labelsAreKeys: Bool { jumping || mode == "tess" }

    /// The letters windows and tabs wear: those tess mode does not use, so they are keys there too.
    var labelPool: String { labelLetters(free: config.modes["tess"] ?? [:]) }

    /// The visible windows, without those under another's tess fullscreen.
    var shownWindows: [WindowID] {
        labeledWindows.filter { id in
            guard let p = world.locate(id), let fs = world.monitors[p.m].fullscreen else { return true }
            return fs == id
        }
    }


    /// Borders and letters on every window, tab letters and numbers on every screen when
    /// letters are keys or labels are always on; otherwise the focused window's border and,
    /// with more than one screen, the active screen's outline (overlay.window_labels).
    func refreshDecorations() {
        labels = stableLabels(labels, windows: labeledWindows, alphabet: labelPool)
        let all = config.windowLabels == .always || labelsAreKeys
        guard config.windowLabels != .off, !paused, !starting else {
            if !drawn.isEmpty { decorations.hide() }
            drawn = []
            return
        }
        let windows = shownWindows.compactMap { id -> Decorations.Window? in
            guard all || id == world.focused, let f = infos[id]?.frame else { return nil }
            return Decorations.Window(frame: f, label: all ? labels[id] : nil, focused: id == world.focused)
        }
        let tabs = zip(tabList, tabLetters).map { (frame: $0.frame, label: $1) }
        let screens = world.monitors.map(\.frame)
        let active = screens.count > 1 ? world.activeMonitor : nil
        let signature = screens.map { "\($0)" } + windows.map { "\($0.frame)\($0.label.map(String.init) ?? "")\($0.focused)" }
            + tabs.map { "\($0.frame)\($0.label)" } + ["\(labelsAreKeys)", "\(all)", "\(active ?? -1)"]
        guard signature != drawn else { return }
        drawn = signature
        decorations.update(screens: screens, windows: windows, tabs: tabs, jumping: labelsAreKeys, all: all, active: active)
    }


    /// While letters are keys, the tabs of the windows on screen (the focused window's first)
    /// take the letters the windows left; their keys and labels follow once every app answered.
    func refreshTabs() {
        tabsAsked += 1
        let asked = tabsAsked
        tabList = []
        tabLetters = []
        guard labelsAreKeys else { return }
        let shown = shownWindows, f = world.focused
        let order = shown.filter { $0 == f } + shown.filter { $0 != f }
        let byApp = Dictionary(grouping: order.filter { infos[$0].flatMap { workers[$0.pid] } != nil }) { infos[$0]!.pid }
        var found: [WindowID: [TabTarget]] = [:]
        var left = byApp.count
        for (pid, ids) in byApp {
            workers[pid]?.tabs(of: ids) { [weak self] tabs in
                guard let self, asked == self.tabsAsked else { return }
                for t in tabs { found[t.window, default: []].append(TabTarget(pid: pid, window: t.window, frame: t.frame, element: t.element)) }
                left -= 1
                guard left == 0 else { return }
                let free = self.labelPool.filter { !self.labels.values.contains($0) }
                self.tabList = Array(order.flatMap { found[$0] ?? [] }.prefix(free.count))
                self.tabLetters = Array(free.prefix(self.tabList.count))
                if self.jumping { self.registerJump() } else { self.registerMode() }
                self.refreshDecorations()
            }
        }
    }


    /// Every window's letter becomes a key (shift swaps with it), every tab's letter and every
    /// screen's number too (shift moves there); one use, or esc, goes back to the mode jump
    /// started from (main from a one-shot mode).
    func startJump() {
        guard !jumping else { return }
        jumpReturn = returnMode
        mode = "jump"
        Events.record("mode", ["mode": "jump"])
        refreshDecorations()
        let exits = registerJump()
        refreshTabs()
        // A cheat sheet like any mode's, for as long as jump mode lasts.
        let n = max(world.monitors.count, 1)
        overlay.showSheet("Jump", rows: [("Letter", "Go to that window or tab"), ("⇧ Letter", "Swap that window with the focused one"),
                                         ("1–\(n)", "Go to that screen"), ("⇧ 1–\(n)", "Move the focused window there")],
                          back: exits.map(\.symbol), on: modeScreens)
        onChange()
    }

    /// Jump mode's keys for the letters and tabs there are now; the keys that leave it.
    @discardableResult
    func registerJump() -> [KeySpec] {
        let (keys, exits) = jumpKeys(labels: labels, windows: labeledWindows, tabs: tabLetters, screens: world.monitors.count,
                                     back: [.mode(jumpReturn)])
        let failed = hotkeys.register(keys)
        if !failed.isEmpty { Log.write("jump: could not register \(failed)") }
        return exits
    }

    /// In tess mode, its bindings plus a key for every window and tab letter (shift+letter swaps).
    var tessLetterKeys: [KeySpec: [Command]] {
        jumpKeys(labels: labels, windows: labeledWindows, tabs: tabLetters, screens: 0, back: []).keys
            .filter { $0.key.key.count == 1 && $0.key.key.first!.isLetter }
    }
}

/// A tab tess labeled: its app, window, where it is, and the element to press.
struct TabTarget {
    var pid: pid_t
    var window: WindowID
    var frame: CGRect
    var element: AXUIElement
}
