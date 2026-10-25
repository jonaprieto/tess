import AppKit
import UniformTypeIdentifiers
import Layout

/// Main thread. Owns the model, turns AX snapshots into model changes, runs commands, and
/// writes frames back through the app workers.
final class Tiler {
    private(set) var world = World()
    private(set) var config = Config.defaults
    private(set) var configError: String?
    private(set) var mode = "main"
    private(set) var paused = false
    /// Called whenever the mode, pause state or config error changes (for the menu bar).
    var onChange: () -> Void = {}
    /// Called after every layout pass (for the menu bar minimap).
    var onLayout: () -> Void = {}

    private var workers: [pid_t: AppWorker] = [:]
    private var infos: [WindowID: WinInfo] = [:]
    /// Last frame written per window and how often, so an app that refuses a size is not
    /// fought forever: three tries per target, reset once the window matches.
    private var writes: [WindowID: (target: CGRect, tries: Int)] = [:]
    /// Snapshots during the first 2 s only collect; then the layout is rebuilt from where
    /// windows are, so a restart keeps it.
    private var starting = true
    /// The window macOS says is focused.
    private var osFocused: WindowID?
    /// After tess focuses a window, macOS gets one contrary report overruled (it likes to
    /// focus another window of the app whose window just closed).
    private var intent: (id: WindowID, until: Date, reasserted: Bool)?
    private var applyScheduled = false
    private var screensWork: DispatchWorkItem?
    /// AX only lists the current Space's windows (a native fullscreen app is a Space of its
    /// own). Windows that drop out of an AX list but still exist are on another Space: they
    /// keep their place and get no frame writes until they are back.
    private var offSpace: Set<WindowID> = []
    /// Space changes counted, and the count when each off-Space window was last listed: a
    /// window unlisted across several Space changes was closed (kept ordered out by its app).
    private var spaceChanges = 0
    private var unlistedSince: [WindowID: Int] = [:]
    /// Windows floated by the classifier rather than the user; reconsidered as they settle.
    private var autoFloated: Set<WindowID> = []
    /// Windows whose app refused the frame tess asked for (a minimum size, usually).
    private var refused: Set<WindowID> = []
    /// A window that leaves the AX list right after a Space change went to another Space;
    /// otherwise it was closed (apps often keep closed windows around, ordered out, so the
    /// window server list alone cannot tell).
    private var spaceChangedAt = Date.distantPast
    /// Window ids only grow: anything at or below this existed before tess started. Such a
    /// window, or one tess has seen before (back from another Space, minimized, hidden), is
    /// placed where it is when it shows up; only brand new windows get a new lane.
    private var preexisting: WindowID = 0
    private var seen: Set<WindowID> = []
    /// From a hotkey there is no terminal: an error becomes a toast.
    private lazy var hotkeys = Hotkeys { [weak self] commands in
        guard let self else { return }
        let out = self.run(commands, source: "hotkey")
        if out.hasPrefix("error: ") { self.toast(String(out.dropFirst(7))) }
    }
    private lazy var picker: Picker = {
        let p = Picker()
        p.onDone = { [weak self] item, choice in self?.picked(item, choice) }
        p.onCancel = { [weak self] in self?.pickerClosed(cancelled: true) }
        p.search = { [weak self] verb, query, done in self?.search(verb, query, done) }
        return p
    }()
    /// The picker is open (or about to open): no hotkeys, no focus changes.
    private var picking = false
    /// The picker was opened by close-replace; cancelling it focuses what tess picked.
    private var closeReplacing = false
    /// An app opened from the picker: its first new window goes to `spot`.
    private var pending: (bundle: String, spot: Spot, until: Date)?
    /// Windows the picker listed from the window server only, with their app.
    private var unseen: [WindowID: pid_t] = [:]
    private var appCache: (apps: [(url: URL, name: String, bundleID: String?, icon: NSImage)], at: Date, folders: [Date])?
    let overlay = Overlay()

    static let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/tess/config.json")

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
            Browsers.history { _ in }  // warm the caches for the picker
            self?.refreshApps()
            _ = self?.picker
        }
        registerMode()
        Log.write("started")
    }

    // MARK: Apps and windows

    private func track(_ app: NSRunningApplication) {
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

    private func untrack(_ pid: pid_t) {
        // didTerminate fires for every process, helpers and ignored apps included.
        guard let worker = workers.removeValue(forKey: pid) else { return }
        worker.stop()
        Events.record("app.quit", ["pid": Int(pid), "bundle": worker.app.bundleIdentifier ?? "", "name": worker.app.localizedName ?? ""])
        let hadFocus = world.focused
        for (id, info) in infos where info.pid == pid { forget(id, "app quit") }
        if let hadFocus, !world.contains(hadFocus) { afterFocusChange() }
        scheduleApply()
    }

    private func forget(_ id: WindowID, _ why: String = "gone") {
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
    static func liveWindowIDs() -> Set<WindowID> {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    /// Windows that were already open when tess started: tiled by where they are, next to
    /// where everything else is going.
    // ponytail: rebuilds the whole layout, so accordion and tess fullscreen are reset; place
    // one window by frame in Layout if that ever bites.
    private func adopt(_ found: [WinInfo]) {
        var flat = world
        for i in flat.monitors.indices { flat.monitors[i].fullscreen = nil }
        let targets = flat.frames(inner: config.inner, outer: config.outer).map { (id: $0.key, frame: $0.value) }
        world.rebuild(targets + found.map { (id: $0.id, frame: $0.frame) })
    }

    private func bundle(_ pid: pid_t) -> String? { workers[pid]?.app.bundleIdentifier }

    private func kind(_ info: WinInfo) -> Kind { info.kind(bundleID: bundle(info.pid), config) }

    private func snapshot(_ pid: pid_t, _ list: [WinInfo], _ focused: WindowID?) {
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
    private func syncFocus(_ id: WindowID) {
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
    private func afterFocusChange() {
        guard let next = world.focused else { return }
        DispatchQueue.main.async { [weak self] in self?.focus(next) }
    }

    /// Never while the picker is open: another app taking focus would close it.
    private func focus(_ id: WindowID) {
        guard !picking else { return }
        Events.record("focus", describe(id).merging(["by": "tess"]) { $1 })
        intent = (id, Date().addingTimeInterval(0.3), false)
        workerFocus(id)
    }

    private func workerFocus(_ id: WindowID) {
        guard let info = infos[id] else { return }
        workers[info.pid]?.focus(id)
    }

    private var sweeps = 0

    /// The frontmost app every 5 s, every app every 30 s (or `all`, after a Space change or
    /// a wake): each refresh costs the app a few AX round trips on its main thread.
    private func sweep(all: Bool = false) {
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
    private func rebuild() {
        let tiles = infos.values.filter { kind($0) == .tile }.sorted { $0.id < $1.id }
        world.rebuild(tiles.map { (id: $0.id, frame: $0.frame) })
        world.floating = Set(infos.values.filter { kind($0) == .float }.map(\.id))
        if let f = osFocused, world.contains(f) { world.focused = f }
        writes = [:]
        apply()
    }

    // MARK: Frames

    private func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.applyScheduled = false
            self?.apply()
        }
    }

    private func apply() {
        defer { onLayout() }
        guard !starting, !paused else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.scheduleApply() }
            return
        }
        for (id, target) in world.frames(inner: config.inner, outer: config.outer) where !offSpace.contains(id) {
            guard let info = infos[id], let worker = workers[info.pid] else { continue }
            if Self.near(info.frame, target) {
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

    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    // MARK: Monitors

    private func screensChanged() {
        screensWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateMonitors() }
        screensWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func updateMonitors() {
        let screens = Screens.current()
        world.setMonitors(screens.map { (id: $0.id, frame: $0.frame) }, main: screens.first(where: \.isMain)?.id)
        writes = [:]
        Log.write("monitors: \(screens.map { "\($0.id.prefix(8)) \(Int($0.frame.width))x\(Int($0.frame.height))" })")
        Events.record("screens", ["screens": screens.enumerated().map { n, s in
            ["n": n + 1, "id": s.id, "frame": s.frame.json, "full": s.full.json, "main": s.isMain] as [String: Any] }])
        if !starting { Events.record("state", stateJSON()) }
        scheduleApply()
    }

    private var activeFrame: CGRect {
        world.monitors.indices.contains(world.activeMonitor) ? world.monitors[world.activeMonitor].frame
            : (Screens.current().first?.frame ?? .zero)
    }

    /// The screen being looked at: the one with macOS's focused window (also when it is a
    /// fullscreen app tess leaves alone), else the one with the mouse.
    private var lookedAtFrame: CGRect {
        if let f = osFocused.flatMap({ infos[$0]?.frame }), let m = world.monitorIndex(for: f) { return world.monitors[m].frame }
        let mouse = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        let p = CGPoint(x: mouse.x, y: h - mouse.y)
        return world.monitors.first { $0.frame.insetBy(dx: 0, dy: -40).contains(p) }?.frame ?? activeFrame
    }

    // MARK: Commands

    /// Runs commands from a hotkey or the CLI; returns what to print.
    /// `source` says where the commands came from (hotkey, cli, menu, picker) for the event log.
    func run(_ commands: [Command], source: String = "internal") -> String {
        let before = world
        let out = commands.map(execute).filter { !$0.isEmpty }.joined(separator: "\n")
        if commands != [.state], commands != [.tree], commands != [.nop] {
            var e: [String: Any] = ["cmd": commands.map(\.description).joined(separator: "; "), "source": source]
            if out.hasPrefix("error: ") { e["error"] = String(out.dropFirst(7)) }
            Events.record("command", e)
        }
        if world != before { Events.record("layout", layoutJSON()) }
        return out
    }

    private func execute(_ c: Command) -> String {
        if paused, ![.pause, .tree, .reload].contains(c) { return "error: paused" }
        Log.write("command: \(c)")
        let before = world.focused
        let beforeMonitor = world.activeMonitor
        var flash = false
        switch c {
        case .focus(let d): world.focus(d); flash = true
        case .move(let d): world.move(d); flash = true
        case .resize(let a, let px): world.resize(a, by: px)
        case .balance: world.balance()
        case .flip: world.flip()
        case .accordion: world.toggleAccordion()
        case .fullscreen:
            world.toggleFullscreen()
            if let f = world.focused, world.locate(f) != nil {
                focus(f)
                let on = world.locate(f).map { world.monitors[$0.m].fullscreen == f } ?? false
                toast(on ? "fullscreen" : "fullscreen off")
            }
        case .nativeFullscreen:
            if let id = world.focused ?? osFocused, let info = infos[id] { workers[info.pid]?.toggleNativeFullscreen(id) }
        case .float:
            guard let id = world.focused ?? osFocused, world.contains(id) else { return "error: no tiled or floating window focused" }
            world.toggleFloating(id)
        case .close:
            guard let id = world.focused ?? osFocused, let info = infos[id] else { return "error: no window focused" }
            workers[info.pid]?.close(id)
        case .focusMonitor(let n): world.focusMonitor(n - 1); flash = true
        case .cycleMonitor(let s): world.cycleMonitor(s); flash = true
        case .moveToMonitor(let n):
            if let id = world.focused, world.floating.contains(id) {
                moveFloating(id, to: n - 1)
            } else {
                world.moveToMonitor(n - 1)
            }
            flash = true
        case .exec(let line):
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", line]
            do { try p.run() } catch { return "error: \(error)" }
        case .reload: loadConfig(announce: true)
        case .mode(let m): setMode(m)
        case .retile:
            sweep(all: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.rebuild()
                self?.toast("re-tiled")
            }
        case .rescue: toast("rescued \(rescue()) windows")
        case .pause: setPaused(!paused)
        case .tree: return tree()
        case .nop: break
        case .pick(let text):
            if picker.isOpen {
                picker.close()
                pickerClosed(cancelled: true)
            } else {
                openPicker(fixed: nil, text: text)
            }
        case .debugMap(let path):
            let png = Picker.render(pickerMap(), size: NSSize(width: 1000, height: 550))
            do { try png?.write(to: URL(fileURLWithPath: path)) } catch { return "error: \(error)" }
            return path
        case .settings: openSettings()
        case .state:
            let data = (try? JSONSerialization.data(withJSONObject: stateJSON(), options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        case .clearMonitor:
            world.clearMonitor()
            flash = true
        case .closeReplace:
            guard let id = world.focused, let s = world.slot(of: id), let info = infos[id] else {
                return "error: no tiled window focused"
            }
            beginPicking()
            closeReplacing = true
            world.remove(id)
            workers[info.pid]?.close(id)
            // Let macOS settle on whatever it focuses next, then take the keyboard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showPicker(fixed: .slot(s.position, alone: s.alone))
            }
        }
        if world.focused != before, let f = world.focused { focus(f) }
        if flash { flashFocus() }
        // The cheat sheet follows to the screen being worked on.
        if mode != "main", world.activeMonitor != beforeMonitor, let m = world.monitors[safe: world.activeMonitor] {
            overlay.showMode(mode, config.modes[mode] ?? [:], on: m.frame)
        }
        scheduleApply()
        return ""
    }

    /// Outlines the focused window (or the active monitor when it has none) once the move has
    /// landed: by then the window's own report says where it really is.
    private func flashFocus(after delay: Double = 0.18) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.overlay.flash(self.world.focused.flatMap { self.infos[$0]?.frame } ?? self.activeFrame)
        }
    }

    private func moveFloating(_ id: WindowID, to m: Int) {
        guard world.monitors.indices.contains(m), let info = infos[id] else { return }
        let target = Self.centered(info.frame.size, in: world.monitors[m].frame)
        workers[info.pid]?.setFrame(id, target)
        infos[id]?.frame = target
        world.activeMonitor = m
    }

    static func centered(_ size: CGSize, in screen: CGRect) -> CGRect {
        let w = min(size.width, screen.width * 0.9), h = min(size.height, screen.height * 0.9)
        return CGRect(x: (screen.midX - w / 2).rounded(), y: (screen.midY - h / 2).rounded(), width: w, height: h)
    }

    /// Every window showing less than a tenth of itself on any screen comes back: tiled ones
    /// get their frame written again, the rest are centered on the active monitor.
    private func rescue() -> Int {
        var n = 0
        let screens = world.monitors.map(\.frame)
        for (id, info) in infos where info.standard && !offSpace.contains(id) {
            let area = info.frame.width * info.frame.height
            let shown = screens.map { s -> Double in
                let x = s.intersection(info.frame)
                return x.isNull ? 0 : x.width * x.height
            }.max() ?? 0
            guard area > 0, shown < 0.1 * area else { continue }
            n += 1
            if world.locate(id) != nil {
                writes[id] = nil
                infos[id]?.frame = .zero
            } else {
                let target = Self.centered(info.frame.size, in: activeFrame)
                workers[info.pid]?.setFrame(id, target)
                infos[id]?.frame = target
            }
        }
        Log.write("rescued \(n)")
        apply()
        return n
    }

    private func setPaused(_ p: Bool) {
        paused = p
        if p {
            hotkeys.unregisterAll()
            overlay.hideMode()
        } else {
            mode = "main"
            registerMode()
            rebuild()
        }
        toast(p ? "paused" : "resumed")
        onChange()
    }

    // MARK: Modes and config

    private func setMode(_ m: String) {
        guard config.modes[m] != nil else { return }
        if m != mode { Events.record("mode", ["mode": m]) }
        mode = m
        registerMode()
        if m == "main" {
            overlay.hideMode()
        } else {
            overlay.showMode(m, config.modes[m] ?? [:], on: lookedAtFrame)
        }
        onChange()
    }

    private func registerMode() {
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

    // MARK: Picker

    private func openPicker(fixed: Spot?, text: String = "") {
        guard !picking else { return }
        beginPicking()
        showPicker(fixed: fixed, text: text)
    }

    /// The window that had focus when the picker opened; it gets it back when nothing is picked.
    private var focusBeforePicker: WindowID?

    private func beginPicking() {
        focusBeforePicker = osFocused ?? world.focused
        picking = true
        hotkeys.unregisterAll()
        overlay.hideMode()
    }

    private func showPicker(fixed: Spot?, text: String = "") {
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            Log.write("picker: ready in \(ms) ms")
            Events.record("picker", ["ready_ms": Int(ms)])
        }
        picker.open(pickerItems(), on: lookedAtFrame, fixed: fixed, verbs: config.verbs, text: text) { [weak self] in
            self?.pickerMap() ?? Picker.Map(monitors: [], windows: [], labels: [:])
        }
        Browsers.tabs { [weak self] tabs in self?.picker.add(tabs) }
        Browsers.history { [weak self] pages in self?.picker.add(pages) }
    }

    private func pickerClosed(cancelled: Bool) {
        picking = false
        setMode(mode)
        if cancelled { Events.record("picker.close", ["why": "cancelled"]) }
        // tess was the active app for the picker: hand the keyboard back. A pick then moves
        // focus on to what was picked.
        if cancelled && closeReplacing {
            afterFocusChange()
        } else if let back = focusBeforePicker, infos[back] != nil {
            focus(back)
        }
        closeReplacing = false
    }

    private func picked(_ item: Picker.Item, _ choice: Picker.Choice) {
        pickerClosed(cancelled: false)
        let how: String
        switch choice {
        case .jump: how = "jump"
        case .place(let spot): how = "\(spot)"
        }
        Events.record("pick", ["kind": "\(item.kind)".components(separatedBy: "(").first ?? "", "title": item.title,
                               "detail": item.detail, "where": how])
        switch item.kind {
        case .window(let id):
            use(id, choice)
        case .tab(let t):
            Browsers.select(t) { [weak self] in
                guard let self, let app = NSRunningApplication.runningApplications(withBundleIdentifier: t.bundleID).first else { return }
                // The browser raises the tab's window; once it has, that window is the pick.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.workers[app.processIdentifier]?.focusedWindow { id in
                        if let id { self.use(id, choice) }
                    }
                }
            }
        case .url(let url, let browser):
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser) else { return }
            if case .place(let spot) = choice { pending = (browser, spot, Date().addingTimeInterval(10)) }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            // A running browser opens a tab in its front window: place that window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, let pid = NSRunningApplication.runningApplications(withBundleIdentifier: browser).first?.processIdentifier
                else { return }
                self.workers[pid]?.focusedWindow { id in
                    guard let id, self.world.contains(id) || self.infos[id] != nil else { return }
                    self.pending = nil
                    self.use(id, choice)
                }
            }
        case .file(let path):
            openFile(path, choice)
        case .pdf(let url, let name):
            toast("downloading \(item.title)")
            let dest = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/\(name)")
            URLSession.shared.downloadTask(with: url) { [weak self] tmp, _, _ in
                let ok = tmp.map { (try? FileManager.default.moveItem(at: $0, to: dest)) != nil
                    || FileManager.default.fileExists(atPath: dest.path) } ?? false
                DispatchQueue.main.async {
                    if ok { self?.openFile(dest.path, choice) } else { self?.toast("could not download it") }
                }
            }.resume()
        case .book(let md5):
            toast("downloading \(item.title)")
            Self.shell("folio get \"$1\"", md5, timeout: 600) { [weak self] out in
                let path = out?.split(separator: "\n").last.map(String.init) ?? ""
                guard FileManager.default.fileExists(atPath: path) else {
                    self?.toast("folio could not download it")
                    return
                }
                self?.openFile(path, choice)
            }
        case .match(let path, let line):
            if case .place(let spot) = choice { pending = ("com.microsoft.VSCode", spot, Date().addingTimeInterval(10)) }
            let code = ["/usr/local/bin/code", "/opt/homebrew/bin/code"].first { FileManager.default.isExecutableFile(atPath: $0) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: code ?? "/usr/bin/open")
            p.arguments = code != nil ? ["-g", "\(path):\(line)"] : ["-a", "Visual Studio Code", path]
            try? p.run()
        case .open(let name, let path):
            guard let app = apps().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                toast("no app named \(name)")
                return
            }
            if case .place(let spot) = choice, let b = app.bundleID { pending = (b, spot, Date().addingTimeInterval(10)) }
            NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app.url,
                                    configuration: NSWorkspace.OpenConfiguration())
        case .app(let url):
            let running = NSWorkspace.shared.runningApplications.first { $0.bundleURL == url }
            let windows = infos.values.filter { $0.pid == running?.processIdentifier && $0.standard }.map(\.id)
            if let id = world.pick(windows) {
                use(id, choice)
                return
            }
            if case .place(let spot) = choice, let b = Bundle(url: url)?.bundleIdentifier {
                pending = (b, spot, Date().addingTimeInterval(10))
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Places (or just jumps to) a window. One on another Space brings its app forward
    /// first, so macOS switches there, and is focused once it has.
    private func use(_ id: WindowID, _ choice: Picker.Choice) {
        let away = offSpace.contains(id) || infos[id] == nil
        if away, let pid = infos[id]?.pid ?? unseen[id] { NSRunningApplication(processIdentifier: pid)?.activate() }
        guard infos[id] != nil else {
            // Known only to the window server: place it once its app has listed it, if ever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                if self?.infos[id] != nil { self?.use(id, choice) }
            }
            return
        }
        if case .place(let spot) = choice { world.place(id, spot) } else if world.contains(id) { world.focused = id }
        if away {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.focus(id) }
        } else {
            focus(id)
        }
        scheduleApply()
        flashFocus(after: away ? 0.8 : 0.18)
    }

    /// Opens a file with its default app; with a place, that app's next window goes there.
    private func openFile(_ path: String, _ choice: Picker.Choice) {
        let url = URL(fileURLWithPath: path)
        if case .place(let spot) = choice, let app = NSWorkspace.shared.urlForApplication(toOpen: url),
           let b = Bundle(url: app)?.bundleIdentifier {
            pending = (b, spot, Date().addingTimeInterval(10))
        }
        NSWorkspace.shared.open(url)
    }

    /// `script` under sh with `arg` as $1 and a PATH that finds Homebrew tools; stdout on the
    /// main thread, nil on failure or after `timeout` seconds.
    static func shell(_ script: String, _ arg: String, timeout: Double, _ done: @escaping (String?) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", arg]
        p.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                         "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            done(nil)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { stop(p) }
        DispatchQueue.global().async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
            DispatchQueue.main.async { done(text) }
        }
    }

    /// Stops a `sh -c` process and what it started (rg, fzf, folio), which would otherwise keep
    /// running and keep the output pipe open.
    static func stop(_ p: Process?) {
        guard let p, p.isRunning else { return }
        let kids = Process()
        kids.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kids.arguments = ["-TERM", "-P", "\(p.processIdentifier)"]
        try? kids.run()
        kids.waitUntilExit()
        p.terminate()
    }

    /// arXiv's API for `query`: open-access papers, best match first.
    static func arxiv(_ query: String, _ done: @escaping ([Picker.Item]) -> Void) {
        // arXiv finds nothing when a required term is a stopword ("attention is all you need").
        let stop: Set<String> = ["a", "an", "the", "is", "are", "of", "in", "on", "for", "and", "or", "to", "with", "all",
                                 "you", "we", "your", "by", "at", "as", "from", "what", "how", "be", "it", "its"]
        let terms = query.lowercased().split(separator: " ").filter { !stop.contains(String($0)) }
            .map { "all:\($0)" }.joined(separator: " AND ")
        var c = URLComponents(string: "https://export.arxiv.org/api/query")!
        c.queryItems = [.init(name: "search_query", value: terms), .init(name: "max_results", value: "10")]
        guard let url = c.url else { return done([]) }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let xml = String(decoding: data ?? Data(), as: UTF8.self)
            func field(_ tag: String, in s: Substring) -> String? {
                guard let a = s.range(of: "<\(tag)>"), let b = s.range(of: "</\(tag)>", range: a.upperBound..<s.endIndex) else { return nil }
                return s[a.upperBound..<b.lowerBound].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            let items = xml.components(separatedBy: "<entry>").dropFirst().compactMap { e -> Picker.Item? in
                let entry = Substring(e)
                guard let id = field("id", in: entry)?.components(separatedBy: "/abs/").last, let title = field("title", in: entry),
                      let pdf = URL(string: "https://arxiv.org/pdf/\(id)") else { return nil }
                let authors = entry.components(separatedBy: "<name>").dropFirst().compactMap { $0.components(separatedBy: "</name>").first }
                let year = String(field("published", in: entry)?.prefix(4) ?? "")
                let surname = authors.first?.split(separator: " ").last.map { $0.lowercased() } ?? "arxiv"
                let slug = title.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(6).joined(separator: "-")
                let detail = (["arXiv", authors.prefix(2).joined(separator: ", ") + (authors.count > 2 ? " et al." : ""), year])
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                return Picker.Item(kind: .pdf(pdf, name: "\(year)-\(surname)-\(slug).pdf"), title: title, detail: detail,
                                   icon: NSWorkspace.shared.icon(for: .pdf), search: "")
            }
            DispatchQueue.main.async { done(items) }
        }.resume()
    }

    private var searchProcess: Process?

    /// `f`: file names from Spotlight, ranked by fzf when it is installed. `rg`: file contents
    /// with ripgrep. Both under the home folder, in the background, the previous one stopped.
    private func search(_ verb: String, _ query: String, _ done: @escaping ([Picker.Item]) -> Void) {
        Self.stop(searchProcess)
        let skip = "-g '!Library' -g '!Movies' -g '!Music' -g '!Pictures' -g '!Applications'"
        let script: String
        switch verb {
        case "f":
            script = """
                mdfind -onlyin "$HOME" -name "$1" 2>/dev/null | grep -v '/Library/' | head -n 500 |
                { if command -v fzf >/dev/null; then fzf --filter "$1"; else cat; fi; } | head -n 60
                """
        case "rg":
            script = """
                cd "$HOME" && rg --line-number --no-heading --smart-case --max-count 1 --max-filesize 1M \
                  --max-columns 160 --max-columns-preview \(skip) -- "$1" . 2>/dev/null | head -n 80
                """
        case "book", "paper":
            // Query words as separate arguments, no globbing.
            script = "set -f; set -- $1; folio search --json -n 25 --ext \(verb == "paper" ? "pdf" : "pdf,epub") -- \"$@\""
        default: return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", query]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        p.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": home]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            done([])
            return
        }
        searchProcess = p
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { Self.stop(p) }
        DispatchQueue.global().async {
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            DispatchQueue.main.async {
                func short(_ path: String) -> String { path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path }
                if verb == "book" || verb == "paper" {
                    let found = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] ?? []
                    let books: [Picker.Item] = found.compactMap { b in
                        guard let md5 = b["md5"] as? String else { return nil }
                        let ext = b["ext"] as? String ?? ""
                        let detail = [b["author"] as? String, b["year"] as? String, ext, b["size"] as? String]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                        return Picker.Item(kind: .book(md5: md5), title: b["title"] as? String ?? md5, detail: detail,
                                           icon: NSWorkspace.shared.icon(for: ext == "epub" ? .epub : .pdf), search: "")
                    }
                    guard verb == "paper" else { return done(books) }
                    Self.arxiv(query) { papers in done(papers + books) }
                    return
                }
                let items = text.split(separator: "\n").compactMap { line -> Picker.Item? in
                    if verb == "f" {
                        let path = String(line)
                        return Picker.Item(kind: .file(path), title: (path as NSString).lastPathComponent,
                                           detail: short((path as NSString).deletingLastPathComponent),
                                           icon: NSWorkspace.shared.icon(forFile: path), search: "")
                    }
                    let f = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                    guard f.count == 3, let n = Int(f[1]) else { return nil }
                    let path = home + "/" + (f[0].hasPrefix("./") ? String(f[0].dropFirst(2)) : f[0])
                    return Picker.Item(kind: .match(path, line: n), title: "\(short(path)):\(n)",
                                       detail: f[2].trimmingCharacters(in: .whitespaces),
                                       icon: NSWorkspace.shared.icon(forFile: path), search: "")
                }
                done(items)
            }
        }
    }

    /// Windows (most recently focused first), then apps.
    private func pickerItems() -> [Picker.Item] {
        var items: [Picker.Item] = []
        var listed = Set<WindowID>()
        for id in world.mru + infos.keys.sorted() where listed.insert(id).inserted {
            guard let info = infos[id], info.standard || info.nativeFullscreen, let app = workers[info.pid]?.app else { continue }
            let name = app.localizedName ?? "?"
            let place = offSpace.contains(id) ? "other Space"
                : "screen \((world.locate(id)?.m ?? world.monitorIndex(for: info.frame) ?? 0) + 1)"
            items.append(Picker.Item(kind: .window(id), title: info.title.isEmpty ? name : info.title,
                                     detail: "\(name) · \(place)", icon: workers[info.pid]?.icon ?? app.icon,
                                     search: "\(name) \(info.title)"))
        }
        // Windows on a Space tess has not seen since it started: AX cannot list them, the
        // window server can (titles only with Screen Recording access).
        unseen = [:]
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in all {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value, !listed.contains(id),
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, let app = workers[pid]?.app,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  ((b["Width"] as? NSNumber)?.doubleValue ?? 0) > 150, ((b["Height"] as? NSNumber)?.doubleValue ?? 0) > 150
            else { continue }
            let title = w[kCGWindowName as String] as? String ?? ""
            // Untitled ones are mostly helper windows; keep one only for an app with no
            // window tess knows, so the app can still be reached on its Space.
            if title.isEmpty && (infos.values.contains { $0.pid == pid } || unseen.values.contains(pid)) { continue }
            unseen[id] = pid
            let name = app.localizedName ?? "?"
            items.append(Picker.Item(kind: .window(id), title: title.isEmpty ? name : title,
                                     detail: "\(name) · other Space", icon: workers[pid]?.icon ?? app.icon,
                                     search: "\(name) \(title)"))
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for a in apps() {
            let open = a.bundleID.map(running.contains) ?? false
            items.append(Picker.Item(kind: .app(a.url), title: a.name, detail: open ? "app (open)" : "app",
                                     icon: a.icon, search: a.name))
        }
        return items
    }

    /// Every app in the usual folders. Scanned off the main thread when tess starts and again
    /// every ten minutes, so opening the picker never waits for the disk.
    private func apps() -> [(url: URL, name: String, bundleID: String?, icon: NSImage)] {
        if let c = appCache { return c.apps }
        let scanned = Self.scanApps(ignoring: config.ignore)
        appCache = (scanned, Date(), Self.appFolderDates())
        return scanned
    }

    /// Rescans only when an app folder changed (an app installed or removed).
    private func refreshApps() {
        let ignore = config.ignore
        let previous = appCache
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let folders = Self.appFolderDates()
            let apps = previous.flatMap { $0.folders == folders ? $0.apps : nil } ?? Self.scanApps(ignoring: ignore)
            DispatchQueue.main.async { self?.appCache = (apps, Date(), folders) }
        }
    }

    private static let appFolders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                                     "/System/Applications/Utilities",
                                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]

    private static func appFolderDates() -> [Date] {
        appFolders.map { (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast }
    }

    private static func scanApps(ignoring ignore: [String]) -> [(url: URL, name: String, bundleID: String?, icon: NSImage)] {
        let fm = FileManager.default
        let dirs = appFolders
        var out: [(url: URL, name: String, bundleID: String?, icon: NSImage)] = []
        for dir in dirs {
            for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(entry)
                let id = Bundle(url: url)?.bundleIdentifier
                if let id, ignore.contains(id) { continue }
                let name = (fm.displayName(atPath: url.path) as NSString).deletingPathExtension
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                out.append((url, name, id, Icons.small(icon) ?? icon))
            }
        }
        out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return out
    }

    private func pickerMap() -> Picker.Map {
        // Without tess fullscreen, so no window is drawn over the others' letters.
        var flat = world
        for i in flat.monitors.indices { flat.monitors[i].fullscreen = nil }
        let frames = flat.frames(inner: config.inner, outer: config.outer)
        var windows: [(id: WindowID, frame: CGRect, app: String, title: String, icon: NSImage?)] = []
        for mon in world.monitors {
            for lane in mon.lanes {
                let rects = lane.windows.compactMap { frames[$0] }
                guard let all = rects.reduce(nil, { (u: CGRect?, r) in u?.union(r) ?? r }) else { continue }
                for (i, id) in lane.windows.enumerated() {
                    // An accordion's windows share one rect; the map lists them as rows instead.
                    let n = CGFloat(lane.windows.count)
                    let r = lane.accordion
                        ? CGRect(x: all.minX, y: all.minY + all.height * CGFloat(i) / n, width: all.width, height: all.height / n)
                        : (frames[id] ?? .zero)
                    let worker = infos[id].flatMap { workers[$0.pid] }
                    windows.append((id, r, worker?.app.localizedName ?? "", infos[id]?.title ?? "", worker?.icon ?? worker?.app.icon))
                }
            }
        }
        return Picker.Map(monitors: world.monitors.map(\.frame), windows: windows, labels: world.labels(Picker.alphabet))
    }

    // MARK: Rescue from the menu

    func menuRescue() { toast("rescued \(rescue()) windows") }

    /// For the menu header: mode, windows, screens.
    var summary: String {
        let n = world.tiled.count + world.floating.count
        return "\(paused ? "paused" : "\(mode) mode") · \(n) window\(n == 1 ? "" : "s") · \(world.monitors.count) screen\(world.monitors.count == 1 ? "" : "s")"
    }

    func openSettings() {
        SettingsWindow.shared.show(raw: config.raw) { [weak self] raw in self?.saveSettings(raw) }
    }

    /// Validates and writes what the settings window changed, then reloads; the error if not.
    func saveSettings(_ raw: Config.Raw) -> String? {
        // Saving now would replace the hand-edited file with these settings.
        if let e = configError { return "config.json has an error, fix it or delete it first: \(e)" }
        do {
            _ = try Config.validate(raw)
            try FileManager.default.createDirectory(at: Self.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Config.file(for: raw).write(to: Self.configURL, options: .atomic)
            loadConfig(announce: true)
            return configError
        } catch {
            return "\(error)"
        }
    }
    func menuRetile() { _ = run([.retile], source: "menu") }
    func menuPause() { _ = run([.pause], source: "menu") }
    func menuReload() { _ = run([.reload], source: "menu") }

    // MARK: tess tree

    // MARK: Event log

    /// A window for the log: id, app, title (cut at 200 characters) and frame.
    private func describe(_ id: WindowID) -> [String: Any] {
        var d: [String: Any] = ["id": Int(id)]
        if let i = infos[id] {
            d["app"] = workers[i.pid]?.app.localizedName ?? ""
            d["bundle"] = bundle(i.pid) ?? ""
            d["title"] = String(i.title.prefix(200))
            d["frame"] = i.frame.json
        }
        return d
    }

    /// Screens with their columns and windows, as the model has them.
    private func layoutJSON() -> [String: Any] {
        ["focused": world.focused.map { Int($0) as Any } ?? NSNull(), "active_screen": world.activeMonitor + 1,
         "screens": world.monitors.enumerated().map { n, m in
            ["n": n + 1, "rows": m.rows, "fullscreen": m.fullscreen.map { Int($0) as Any } ?? NSNull(),
             "lanes": m.lanes.map { ["windows": $0.windows.map { Int($0) }, "accordion": $0.accordion] as [String: Any] }]
                as [String: Any] }]
    }

    /// Everything tess knows, and the machine it runs on.
    func stateJSON() -> [String: Any] {
        var state = layoutJSON()
        let frames = world.frames(inner: config.inner, outer: config.outer)
        state["mode"] = mode
        state["paused"] = paused
        state["config_error"] = configError ?? NSNull()
        state["frontmost"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        state["machine"] = Events.machine()
        state["apps"] = workers.values.map { ["pid": Int($0.pid), "bundle": $0.app.bundleIdentifier ?? "", "name": $0.app.localizedName ?? ""] }
        state["windows"] = infos.keys.sorted().map { id -> [String: Any] in
            var d = describe(id)
            d["place"] = offSpace.contains(id) ? "other Space" : world.floating.contains(id) ? "floating"
                : world.locate(id) != nil ? "tiled" : "not tiled"
            if let f = frames[id] { d["target"] = f.json }
            if refused.contains(id) { d["keeps_own_size"] = true }
            return d
        }
        return state
    }

    private func tree() -> String {
        func name(_ id: WindowID) -> String {
            guard let i = infos[id] else { return "\(id)" }
            let app = workers[i.pid]?.app.localizedName ?? "?"
            return "\(id) \(app): \(i.title)\(id == world.focused ? "  <- focused" : "")\(offSpace.contains(id) ? "  (other Space)" : "")"
        }
        let frames = world.frames(inner: config.inner, outer: config.outer)
        var out = ["mode \(mode)\(paused ? " (paused)" : "")"]
        for (m, mon) in world.monitors.enumerated() {
            let f = mon.frame
            out.append("monitor \(m + 1) \(mon.id.prefix(8)) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
                + " \(mon.rows ? "rows" : "columns")\(m == world.activeMonitor ? " active" : "")")
            for (l, lane) in mon.lanes.enumerated() {
                out.append("  \(mon.rows ? "row" : "column") \(l + 1)\(lane.accordion ? " accordion" : "")")
                for id in lane.windows {
                    let r = frames[id] ?? .zero
                    out.append("    \(name(id))  [\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))]"
                        + (mon.fullscreen == id ? " fullscreen" : "") + (refused.contains(id) ? " (keeps its own size)" : ""))
                }
            }
        }
        if !world.floating.isEmpty {
            out.append("floating")
            out += world.floating.sorted().map { "  \(name($0))" }
        }
        let left = infos.values.filter { !world.contains($0.id) }.sorted { $0.id < $1.id }
        if !left.isEmpty {
            out.append("not tiled")
            out += left.map { i in
                "  \(name(i.id))  [\(Int(i.frame.minX)),\(Int(i.frame.minY)) \(Int(i.frame.width))x\(Int(i.frame.height))]"
                    + "\(i.standard ? "" : " not-standard")\(i.nativeFullscreen ? " native-fullscreen" : "")"
            }
        }
        out.append("apps: \(workers.count)")
        return out.joined(separator: "\n")
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
