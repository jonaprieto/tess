import AppKit
import Layout

/// Main thread. Owns the model, turns AX snapshots into model changes, runs commands, and
/// writes frames back through the app workers.
final class Tiler {
    var world = World()

    var config = Config.defaults

    var configError: String?

    var mode = "main"

    var paused = false

    /// Called whenever the mode, pause state or config error changes (for the menu bar).
    var onChange: () -> Void = {}

    /// Called after every layout pass (for the menu bar minimap).
    var onLayout: () -> Void = {}


    var workers: [pid_t: AppWorker] = [:]

    var infos: [WindowID: WinInfo] = [:]

    /// Last frame written per window and how often, so an app that refuses a size is not
    /// fought forever: three tries per target, reset once the window matches.
    var writes: [WindowID: (target: CGRect, tries: Int)] = [:]

    /// Snapshots during the first 2 s only collect; then the layout is rebuilt from where
    /// windows are, so a restart keeps it.
    var starting = true

    /// The window macOS says is focused.
    var osFocused: WindowID?

    /// After tess focuses a window, macOS gets one contrary report overruled (it likes to
    /// focus another window of the app whose window just closed).
    var intent: (id: WindowID, until: Date, reasserted: Bool)?

    var applyScheduled = false

    var screensWork: DispatchWorkItem?

    /// AX only lists the current Space's windows (a native fullscreen app is a Space of its
    /// own). Windows that drop out of an AX list but still exist are on another Space: they
    /// keep their place and get no frame writes until they are back.
    var offSpace: Set<WindowID> = []

    /// Space changes counted, and the count when each off-Space window was last listed: a
    /// window unlisted across several Space changes was closed (kept ordered out by its app).
    var spaceChanges = 0

    var unlistedSince: [WindowID: Int] = [:]

    /// Windows floated by the classifier rather than the user; reconsidered as they settle.
    var autoFloated: Set<WindowID> = []

    /// Windows whose app refused the frame tess asked for (a minimum size, usually).
    var refused: Set<WindowID> = []

    /// A window that leaves the AX list right after a Space change went to another Space;
    /// otherwise it was closed (apps often keep closed windows around, ordered out, so the
    /// window server list alone cannot tell).
    var spaceChangedAt = Date.distantPast

    /// Window ids only grow: anything at or below this existed before tess started. Such a
    /// window, or one tess has seen before (back from another Space, minimized, hidden), is
    /// placed where it is when it shows up; only brand new windows get a new lane.
    var preexisting: WindowID = 0

    var seen: Set<WindowID> = []

    /// From a hotkey there is no terminal: an error becomes a toast.
    lazy var hotkeys = Hotkeys { [weak self] commands in
        guard let self else { return }
        let out = self.run(commands, source: "hotkey")
        if out.hasPrefix("error: ") { self.toast(String(out.dropFirst(7))) }
    }

    lazy var picker: Picker = {
        let p = Picker()
        p.onDone = { [weak self] item, choice in self?.picked(item, choice) }
        p.onCancel = { [weak self] in self?.pickerClosed(cancelled: true) }
        p.search = { [weak self] verb, query, done in self?.search(verb, query, done) }
        return p
    }()

    /// The picker is open (or about to open): no hotkeys, no focus changes.
    var picking = false

    /// The picker was opened by close-replace; cancelling it focuses what tess picked.
    var closeReplacing = false

    /// An app opened from the picker: its first new window goes to `spot`.
    var pending: (bundle: String, spot: Spot, until: Date)?

    /// Windows the picker listed from the window server only, with their app.
    var unseen: [WindowID: pid_t] = [:]

    var appCache: (apps: [(url: URL, name: String, bundleID: String?, icon: NSImage)], at: Date, folders: [Date])?

    let overlay = Overlay()


    static let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tess/config.json")


    nonisolated(unsafe) private static var liveCache: (ids: Set<WindowID>, at: Date)?


    var sweeps = 0


    /// The window that had focus when the picker opened; it gets it back when nothing is picked.
    var focusBeforePicker: WindowID?

    let decorations = Decorations()

    /// Each window's letter, kept while the window lives (decorations, jump mode, picker map).
    var labels: [WindowID: Character] = [:]

    var jumpReturn = "main"

    /// The mode before the current one, for `mode back`.
    var modeBefore = "main"

    var drawn: [String] = []

    /// Layout changes, oldest first; the last `undone` of them were undone.
    var history: [Step] = []

    var undone = 0

    /// Zen's timer while it is on, and whether it is in a work block.
    var zen: Pomodoro?

    var zenWorking = false

    var zenTimer: Timer?

    let veil = Veil()


    var searchProcess: Process?


    static let appFolders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                             "/System/Applications/Utilities",
                             FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]


    func start(restartedAfterHang: Bool) {
        preexisting = Self.liveWindowIDs().max() ?? 0
        loadConfig(announce: false)
        updateMonitors()
        let ws = NSWorkspace.shared.notificationCenter
        func onApp(_ name: Notification.Name, _ body: @escaping (NSRunningApplication) -> Void) {
            ws.addObserver(forName: name, object: nil, queue: .main) { n in
                if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { body(app) }
            }
        }
        onApp(NSWorkspace.didLaunchApplicationNotification) { [weak self] in self?.track($0) }
        onApp(NSWorkspace.didTerminateApplicationNotification) { [weak self] in self?.untrack($0.processIdentifier) }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            onApp(name) { [weak self] app in
                self?.track(app)
                self?.workers[app.processIdentifier]?.scheduleRefresh()
            }
        }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.spaceChangedAt = Date()
            self?.spaceChanges += 1
            Events.record("space", ["frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""])
            self?.sweep(all: true)
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Events.record("wake")
            self?.screensChanged()
            self?.sweep(all: true)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.screensChanged() }
        NSWorkspace.shared.runningApplications.forEach(track)
        // A safety net: AX notifications report nearly everything as it happens.
        let sweepTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.sweep() }
        sweepTimer.tolerance = 1
        // A full picture every ten minutes, between the change events.
        let stateTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            if let self { Events.record("state", self.stateJSON()) }
        }
        stateTimer.tolerance = 30
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.starting = false
            self?.rebuild()
            if let self { Events.record("start", ["version": version, "restarted_after_hang": restartedAfterHang, "state": self.stateJSON()]) }
            if restartedAfterHang { self?.toast("restarted after a hang") }
            if let self { Browsers.history(self.config.history) { _ in } }  // warm the caches for the picker
            self?.refreshApps()
            _ = self?.picker
        }
        registerMode()
        Log.write("started")
    }


    // MARK: Apps and windows

    // MARK: Apps and windows

    func track(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard workers[pid] == nil, !app.isTerminated, app.activationPolicy == .regular, pid != getpid(),
              app.bundleIdentifier != "com.apple.loginwindow",
              !config.ignore.contains(app.bundleIdentifier ?? "") else { return }
        Events.record("app.open", ["pid": Int(pid), "bundle": app.bundleIdentifier ?? "", "name": app.localizedName ?? ""])
        let worker = AppWorker(app) { [weak self] pid, list, focused in self?.snapshot(pid, list, focused) }
        workers[pid] = worker
        DispatchQueue.global(qos: .utility).async {
            let icon = Icons.small(app.icon)
            DispatchQueue.main.async { worker.icon = icon }
        }
    }


    func untrack(_ pid: pid_t) {
        // didTerminate fires for every process, helpers and ignored apps included.
        guard let worker = workers.removeValue(forKey: pid) else { return }
        worker.stop()
        Events.record("app.quit", ["pid": Int(pid), "bundle": worker.app.bundleIdentifier ?? "", "name": worker.app.localizedName ?? ""])
        let hadFocus = world.focused
        for (id, info) in infos where info.pid == pid { forget(id, "app quit") }
        if let hadFocus, !world.contains(hadFocus) { afterFocusChange() }
        scheduleApply()
    }


    func forget(_ id: WindowID, _ why: String = "gone") {
        if infos[id] != nil { Events.record("window.close", describe(id).merging(["why": why]) { $1 }) }
        infos[id] = nil
        writes[id] = nil
        offSpace.remove(id)
        unlistedSince[id] = nil
        autoFloated.remove(id)
        refused.remove(id)
        world.remove(id)
    }


    /// Every window that exists, on any Space.
    /// Every window that exists, on any Space. About 15 ms with a few hundred windows, and a
    /// Space switch asks once per app: one answer serves a second.
    static func liveWindowIDs() -> Set<WindowID> {
        if let c = liveCache, Date().timeIntervalSince(c.at) < 1 { return c.ids }
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        liveCache = (ids, Date())
        return ids
    }


    /// Windows that were already open when tess started: tiled by where they are, next to
    /// where everything else is going.
    // ponytail: rebuilds the whole layout, so accordion and tess fullscreen are reset; place
    // one window by frame in Layout if that ever bites.
    func adopt(_ found: [WinInfo]) {
        var flat = world
        for i in flat.monitors.indices { flat.monitors[i].fullscreen = nil }
        let targets = flat.frames(inner: config.inner, outer: config.outer).map { (id: $0.key, frame: $0.value) }
        world.rebuild(targets + found.map { (id: $0.id, frame: $0.frame) })
    }


    func bundle(_ pid: pid_t) -> String? { workers[pid]?.app.bundleIdentifier }


    func kind(_ info: WinInfo) -> WinInfo.Kind { info.kind(bundleID: bundle(info.pid), config) }


    func snapshot(_ pid: pid_t, _ list: [WinInfo], _ focused: WindowID?) {
        guard workers[pid] != nil else { return }
        let listed = Set(list.map(\.id))
        let hadFocus = world.focused
        // Only windows that just went missing: known off-Space ones need no new lookup.
        let missing = infos.values.filter { $0.pid == pid && !listed.contains($0.id) && !offSpace.contains($0.id) }.map(\.id)
        if !missing.isEmpty {
            let live = Self.liveWindowIDs()
            let spaceChange = Date().timeIntervalSince(spaceChangedAt) < 1.5
            for id in missing {
                if spaceChange && live.contains(id) {
                    if offSpace.insert(id).inserted { Events.record("window.away", describe(id)) }
                    unlistedSince[id] = unlistedSince[id] ?? spaceChanges
                } else if !offSpace.contains(id) {
                    forget(id, "closed")
                }
            }
        }
        for info in list {
            infos[info.id] = info
            if offSpace.remove(info.id) != nil { Events.record("window.back", describe(info.id)) }
            unlistedSince[info.id] = nil
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        if frontmost { osFocused = focused }
        let known = seen
        seen.formUnion(listed)
        guard !starting, !paused else { return }
        var found: [WinInfo] = []
        for info in list {
            switch kind(info) {
            case .skip:
                if world.contains(info.id) {
                    world.remove(info.id)
                    Events.record("window.untiled", describe(info.id).merging(
                        ["why": info.nativeFullscreen ? "native fullscreen" : "minimized or hidden"]) { $1 })
                }
            case .tile where !world.contains(info.id):
                if info.id <= preexisting || known.contains(info.id) {
                    found.append(info)
                    Events.record("window.open", describe(info.id).merging(["how": "adopted where it was"]) { $1 })
                } else if let p = pending, p.bundle == bundle(pid), Date() < p.until {
                    // The app picked in the picker: its first window goes where step 2 said.
                    pending = nil
                    world.place(info.id, p.spot)
                    Events.record("window.open", describe(info.id).merging(["how": "placed from the picker"]) { $1 })
                } else if config.emptyScreens, let m = world.emptyMonitor {
                    world.place(info.id, .monitor(m))
                    Events.record("window.open", describe(info.id).merging(["how": "empty screen \(m + 1)"]) { $1 })
                    announce(info.id, on: m)
                } else {
                    world.insert(info.id)
                    Events.record("window.open", describe(info.id).merging(["how": "new column"]) { $1 })
                }
            case .float:
                if !world.contains(info.id) {
                    world.floating.insert(info.id)
                    autoFloated.insert(info.id)
                    Events.record("window.open", describe(info.id).merging(["how": "floating"]) { $1 })
                }
            case .tile:
                // Floated only because it looked like a dialog at first (no fullscreen button
                // yet, a slow read): it is a normal window now.
                if autoFloated.remove(info.id) != nil, world.floating.contains(info.id) {
                    world.floating.remove(info.id)
                    world.insert(info.id)
                }
            }
        }
        if !found.isEmpty { adopt(found) }
        // A background app opening a window does not take focus.
        if !frontmost, world.focused != hadFocus, let hadFocus, world.contains(hadFocus) { world.focused = hadFocus }
        if let hadFocus, !world.contains(hadFocus) {
            // The focused window closed (or was minimized): tess's pick, not macOS's.
            afterFocusChange()
        } else if frontmost, let focused {
            syncFocus(focused)
        }
        scheduleApply()
    }


    /// macOS moved focus (a click, cmd-tab, a window closing).
    func syncFocus(_ id: WindowID) {
        // Overrule macOS once; a second contrary report is the user's own choice.
        if let it = intent, Date() < it.until, it.id != id, world.contains(it.id), !it.reasserted {
            intent?.reasserted = true
            workerFocus(it.id)
            return
        }
        guard world.contains(id) else { return }
        if world.focused != id {
            world.focused = id
            Events.record("focus", describe(id).merging(["by": "macos"]) { $1 })
        }
        if world.floating.contains(id), let f = infos[id]?.frame, let m = world.monitorIndex(for: f) { world.activeMonitor = m }
    }


    /// The focused window left: give macOS a runloop pass, then focus tess's choice.
    func afterFocusChange() {
        guard let next = world.focused else { return }
        DispatchQueue.main.async { [weak self] in self?.focus(next) }
    }


    /// Never while the picker is open: another app taking focus would close it.
    func focus(_ id: WindowID) {
        guard !picking else { return }
        Events.record("focus", describe(id).merging(["by": "tess"]) { $1 })
        intent = (id, Date().addingTimeInterval(0.3), false)
        workerFocus(id)
    }


    func workerFocus(_ id: WindowID) {
        guard let info = infos[id] else { return }
        workers[info.pid]?.focus(id)
    }


    /// The frontmost app every 5 s, every app every 30 s (or `all`, after a Space change or
    /// a wake): each refresh costs the app a few AX round trips on its main thread.
    func sweep(all: Bool = false) {
        sweeps += 1
        let everything = all || sweeps % 6 == 0
        NSWorkspace.shared.runningApplications.forEach(track)
        if let c = appCache, Date().timeIntervalSince(c.at) > 600 { refreshApps() }
        if everything {
            if !offSpace.isEmpty {
                let live = Self.liveWindowIDs()
                for id in offSpace where !live.contains(id) || spaceChanges - (unlistedSince[id] ?? spaceChanges) >= 4 {
                    forget(id, "closed while on another Space")
                }
            }
            // Nothing in the layout without a window behind it, and writes refused earlier
            // get another three tries.
            for id in world.tiled + Array(world.floating) where infos[id] == nil && !offSpace.contains(id) { world.remove(id) }
            writes = [:]
            scheduleApply()
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for (pid, w) in workers {
            if w.app.isTerminated { untrack(pid) } else if everything || pid == front { w.scheduleRefresh() }
        }
    }


    /// Re-tiles every known window from where it is now.
    func rebuild() {
        let tiles = infos.values.filter { kind($0) == .tile }.sorted { $0.id < $1.id }
        world.rebuild(tiles.map { (id: $0.id, frame: $0.frame) })
        world.floating = Set(infos.values.filter { kind($0) == .float }.map(\.id))
        if let f = osFocused, world.contains(f) { world.focused = f }
        writes = [:]
        apply()
    }


    // MARK: Frames

    // MARK: Frames

    func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.applyScheduled = false
            self?.apply()
        }
    }


    /// Where each window goes: the layout's frames, with Zen's window filling its screen.
    var targets: [WindowID: CGRect] {
        var out = world.frames(inner: config.inner, outer: config.outer)
        // ponytail: Zen fills the screen here, not in the model, so leaving it restores nothing and
        // undo never sees it; a re-tile during Zen reads the filled frame, as under fullscreen.
        if zenWorking, let f = world.focused, let p = world.locate(f) { out[f] = world.monitors[p.m].frame }
        return out
    }


    func apply() {
        defer {
            onLayout()
            refreshDecorations()
            refreshVeil()
        }
        guard !starting, !paused else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.scheduleApply() }
            return
        }
        for (id, target) in targets where !offSpace.contains(id) {
            guard let info = infos[id], let worker = workers[info.pid] else { continue }
            if info.frame.isNear(target) {
                writes[id] = (target, 0)
                refused.remove(id)
                continue
            }
            var w = writes[id] ?? (target, 0)
            if w.target != target { w = (target, 0) }
            guard w.tries < 3 else {
                if refused.insert(id).inserted {
                    Log.write("window \(id) keeps its own size (\(info.frame), wanted \(target))")
                    Events.record("frame.refused", describe(id).merging(["wanted": target.json]) { $1 })
                }
                continue
            }
            w.tries += 1
            writes[id] = w
            worker.setFrame(id, target)
            // Assume it lands; the next snapshot says otherwise if not.
            infos[id]?.frame = target
        }
    }


    // MARK: Monitors


    // MARK: Monitors

    func screensChanged() {
        screensWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateMonitors() }
        screensWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }


    func updateMonitors() {
        let screens = Screens.current()
        world.setMonitors(screens.map { (id: $0.id, frame: $0.frame) }, main: screens.first(where: \.isMain)?.id)
        writes = [:]
        Log.write("monitors: \(screens.map { "\($0.id.prefix(8)) \(Int($0.frame.width))x\(Int($0.frame.height))" })")
        Events.record("screens", ["screens": screens.enumerated().map { n, s in
            ["n": n + 1, "id": s.id, "frame": s.frame.json, "full": s.full.json, "main": s.isMain] as [String: Any] }])
        if !starting { Events.record("state", stateJSON()) }
        scheduleApply()
    }


    var activeFrame: CGRect {
        world.monitors.indices.contains(world.activeMonitor) ? world.monitors[world.activeMonitor].frame
            : (Screens.current().first?.frame ?? .zero)
    }


    /// Where a mode's keys show: the screen with the fewest windows (empty_screens), every
    /// screen, or (overlay.all_screens false) the one in use.
    var modeScreens: [CGRect] {
        guard !world.monitors.isEmpty else { return [lookedAtFrame] }
        if config.emptyScreens { return [leastBusyFrame] }
        return config.overlayAllScreens ? world.monitors.map(\.frame) : [lookedAtFrame]
    }

    /// The screen with the fewest windows, the one being looked at on a tie.
    var leastBusyFrame: CGRect {
        let looked = lookedAtFrame
        let m = world.leastBusy(prefer: world.monitors.firstIndex { $0.frame == looked } ?? world.activeMonitor)
        return world.monitors[safe: m]?.frame ?? looked
    }

    /// A new window sent to another screen says where it went.
    func announce(_ id: WindowID, on m: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let screen = self.world.monitors[safe: m]?.frame else { return }
            self.overlay.toast("\(self.appName(id)) opened on screen \(m + 1)", on: screen)
            if let f = self.world.frames(inner: self.config.inner, outer: self.config.outer)[id] { self.overlay.flash(f) }
        }
    }


    /// The screen being looked at: the one with macOS's focused window (also when it is a
    /// fullscreen app tess leaves alone), else the one with the mouse.
    var lookedAtFrame: CGRect {
        if let f = osFocused.flatMap({ infos[$0]?.frame }), let m = world.monitorIndex(for: f) { return world.monitors[m].frame }
        let mouse = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        let p = CGPoint(x: mouse.x, y: h - mouse.y)
        return world.monitors.first { $0.frame.insetBy(dx: 0, dy: -40).contains(p) }?.frame ?? activeFrame
    }


    // MARK: Modes and config

    // MARK: Modes and config

    /// `back` is the mode the current one was entered from (resize returns to tess mode).
    func setMode(_ requested: String) {
        let m = requested == "back" ? modeBefore : requested
        guard config.modes[m] != nil else { return }
        if m != mode {
            if requested != "back" { modeBefore = jumping ? jumpReturn : mode }
            Events.record("mode", ["mode": m])
        }
        mode = m
        registerMode()
        if m == "main" {
            overlay.hideMode()
        } else {
            overlay.showMode(m, config.modes[m] ?? [:], on: modeScreens)
        }
        onChange()
    }


    func registerMode() {
        guard !paused else { return }
        let failed = hotkeys.register(config.modes[mode] ?? [:])
        if !failed.isEmpty {
            Log.write("could not register: \(failed)")
            toast("could not register \(failed.joined(separator: ", "))")
        }
    }


    func loadConfig(announce: Bool) {
        let url = Self.configURL
        do {
            config = try Config.load(FileManager.default.fileExists(atPath: url.path) ? Data(contentsOf: url) : nil)
            configError = nil
            Events.record("config", ["ok": true])
            if announce { toast("config reloaded") }
        } catch {
            configError = "\(error)"
            Log.write("config: \(error)")
            Events.record("config", ["ok": false, "error": "\(error)"])
            toast("\(error)")
        }
        for (pid, w) in workers where config.ignore.contains(w.app.bundleIdentifier ?? "") { untrack(pid) }
        mode = "main"
        overlay.hideMode()
        registerMode()
        if announce { sweep(all: true) }
        onChange()
    }


    func toast(_ s: String) { overlay.toast(s, on: lookedAtFrame) }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
