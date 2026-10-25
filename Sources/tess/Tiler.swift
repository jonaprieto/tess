import AppKit
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
    /// A window that leaves the AX list right after a Space change went to another Space;
    /// otherwise it was closed (apps often keep closed windows around, ordered out, so the
    /// window server list alone cannot tell).
    private var spaceChangedAt = Date.distantPast
    /// Window ids only grow: anything at or below this existed before tess started. Such a
    /// window, or one tess has seen before (back from another Space, minimized, hidden), is
    /// placed where it is when it shows up; only brand new windows get a new lane.
    private var preexisting: WindowID = 0
    private var seen: Set<WindowID> = []
    private lazy var hotkeys = Hotkeys { [weak self] commands in _ = self?.run(commands) }
    private lazy var picker: Picker = {
        let p = Picker()
        p.onDone = { [weak self] item, choice in self?.picked(item, choice) }
        p.onCancel = { [weak self] in self?.pickerClosed(cancelled: true) }
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
    private var appCache: (apps: [(url: URL, name: String, bundleID: String?, icon: NSImage)], at: Date)?
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
            self?.sweep()
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged()
            self?.sweep()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.screensChanged() }
        NSWorkspace.shared.runningApplications.forEach(track)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sweep() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.starting = false
            self?.rebuild()
            if restartedAfterHang { self?.toast("restarted after a hang") }
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
        workers[pid] = AppWorker(app) { [weak self] pid, list, focused in self?.snapshot(pid, list, focused) }
    }

    private func untrack(_ pid: pid_t) {
        workers.removeValue(forKey: pid)?.stop()
        for (id, info) in infos where info.pid == pid { forget(id) }
        afterFocusChange()
        scheduleApply()
    }

    private func forget(_ id: WindowID) {
        infos[id] = nil
        writes[id] = nil
        offSpace.remove(id)
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
        let missing = infos.values.filter { $0.pid == pid && !listed.contains($0.id) }.map(\.id)
        if !missing.isEmpty {
            let live = Self.liveWindowIDs()
            let spaceChange = Date().timeIntervalSince(spaceChangedAt) < 1.5
            for id in missing {
                if spaceChange && live.contains(id) { offSpace.insert(id) } else if !offSpace.contains(id) { forget(id) }
            }
        }
        for info in list {
            infos[info.id] = info
            offSpace.remove(info.id)
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        if frontmost { osFocused = focused }
        let known = seen
        seen.formUnion(listed)
        guard !starting, !paused else { return }
        var found: [WinInfo] = []
        for info in list {
            switch kind(info) {
            case .skip: if world.contains(info.id) { world.remove(info.id) }
            case .tile where !world.contains(info.id):
                if info.id <= preexisting || known.contains(info.id) {
                    found.append(info)
                } else if let p = pending, p.bundle == bundle(pid), Date() < p.until {
                    // The app picked in the picker: its first window goes where step 2 said.
                    pending = nil
                    world.place(info.id, p.spot)
                } else {
                    world.insert(info.id)
                }
            case .float: if !world.contains(info.id) { world.floating.insert(info.id) }
            case .tile: break
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
        if let it = intent, Date() < it.until, it.id != id, world.contains(it.id) {
            if !it.reasserted {
                intent?.reasserted = true
                workerFocus(it.id)
            }
            return
        }
        guard world.contains(id) else { return }
        if world.focused != id { world.focused = id }
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
        intent = (id, Date().addingTimeInterval(0.3), false)
        workerFocus(id)
    }

    private func workerFocus(_ id: WindowID) {
        guard let info = infos[id] else { return }
        workers[info.pid]?.focus(id)
    }

    private func sweep() {
        NSWorkspace.shared.runningApplications.forEach(track)
        if !offSpace.isEmpty {
            let live = Self.liveWindowIDs()
            for id in offSpace where !live.contains(id) { forget(id) }
            scheduleApply()
        }
        for (pid, w) in workers {
            if w.app.isTerminated { untrack(pid) } else { w.scheduleRefresh() }
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
                continue
            }
            var w = writes[id] ?? (target, 0)
            if w.target != target { w = (target, 0) }
            guard w.tries < 3 else { continue }
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
        scheduleApply()
    }

    private var activeFrame: CGRect {
        world.monitors.indices.contains(world.activeMonitor) ? world.monitors[world.activeMonitor].frame
            : (Screens.current().first?.frame ?? .zero)
    }

    // MARK: Commands

    /// Runs commands from a hotkey or the CLI; returns what to print.
    func run(_ commands: [Command]) -> String {
        commands.map(execute).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private func execute(_ c: Command) -> String {
        if paused, ![.pause, .tree, .reload].contains(c) { return "error: paused" }
        Log.write("command: \(c)")
        let before = world.focused
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
            if let f = world.focused { focus(f) }
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
            sweep()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.rebuild()
                self?.toast("re-tiled")
            }
        case .rescue: toast("rescued \(rescue()) windows")
        case .pause: setPaused(!paused)
        case .tree: return tree()
        case .nop: break
        case .pick:
            if picker.isOpen {
                picker.close()
                pickerClosed(cancelled: true)
            } else {
                openPicker(fixed: nil)
            }
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
        if flash {
            let frames = world.frames(inner: config.inner, outer: config.outer)
            overlay.flash(world.focused.flatMap { frames[$0] ?? infos[$0]?.frame } ?? activeFrame)
        }
        scheduleApply()
        return ""
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
        mode = m
        registerMode()
        if m == "main" {
            overlay.hideMode()
        } else {
            let rows = (config.modes[m] ?? [:]).map { binding in
                let all = binding.key.mods.count == Mod.allCases.count
                return (key: all ? "hyper-\(binding.key.key)" : binding.key.description,
                        command: binding.value.map(\.description).joined(separator: "; "))
            }
            overlay.showMode(m, rows.sorted { $0.key < $1.key }, on: activeFrame)
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
            if announce { toast("config reloaded") }
        } catch {
            configError = "\(error)"
            Log.write("config: \(error)")
            toast("\(error)")
        }
        for (pid, w) in workers where config.ignore.contains(w.app.bundleIdentifier ?? "") { untrack(pid) }
        mode = "main"
        overlay.hideMode()
        registerMode()
        if announce { sweep() }
        onChange()
    }

    func toast(_ s: String) { overlay.toast(s, on: activeFrame) }

    // MARK: Picker

    private func openPicker(fixed: Spot?) {
        guard !picking else { return }
        beginPicking()
        showPicker(fixed: fixed)
    }

    private func beginPicking() {
        picking = true
        hotkeys.unregisterAll()
        overlay.hideMode()
    }

    private func showPicker(fixed: Spot?) {
        picker.open(pickerItems(), on: activeFrame, fixed: fixed) { [weak self] in
            self?.pickerMap() ?? Picker.Map(monitors: [], windows: [], labels: [:])
        }
        Browsers.tabs { [weak self] tabs in self?.picker.add(tabs) }
    }

    private func pickerClosed(cancelled: Bool) {
        picking = false
        setMode(mode)
        if cancelled && closeReplacing { afterFocusChange() }
        closeReplacing = false
    }

    private func picked(_ item: Picker.Item, _ choice: Picker.Choice) {
        pickerClosed(cancelled: false)
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
        if case .place(let spot) = choice { world.place(id, spot) } else if world.contains(id) { world.focused = id }
        if away {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.focus(id) }
        } else {
            focus(id)
        }
        scheduleApply()
        let frames = world.frames(inner: config.inner, outer: config.outer)
        if let r = frames[id] ?? infos[id]?.frame { overlay.flash(r) }
    }

    /// Windows (most recently focused first), then apps.
    private func pickerItems() -> [Picker.Item] {
        var items: [Picker.Item] = []
        var listed = Set<WindowID>()
        for id in world.mru + infos.keys.sorted() where listed.insert(id).inserted {
            guard let info = infos[id], info.standard || info.nativeFullscreen, let app = workers[info.pid]?.app else { continue }
            let name = app.localizedName ?? "?"
            let place = offSpace.contains(id) ? "other Space"
                : "monitor \((world.locate(id)?.m ?? world.monitorIndex(for: info.frame) ?? 0) + 1)"
            items.append(Picker.Item(kind: .window(id), title: info.title.isEmpty ? name : info.title,
                                     detail: "\(name) · \(place)", icon: app.icon, search: "\(name) \(info.title)"))
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
                                     detail: "\(name) · other Space", icon: app.icon, search: "\(name) \(title)"))
        }
        for a in apps() {
            let open = a.bundleID.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false
            items.append(Picker.Item(kind: .app(a.url), title: a.name, detail: open ? "app (open)" : "app",
                                     icon: a.icon, search: a.name))
        }
        return items
    }

    /// Every app in the usual folders, read again after a minute.
    private func apps() -> [(url: URL, name: String, bundleID: String?, icon: NSImage)] {
        if let c = appCache, Date().timeIntervalSince(c.at) < 60 { return c.apps }
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                    fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var out: [(url: URL, name: String, bundleID: String?, icon: NSImage)] = []
        for dir in dirs {
            for entry in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where entry.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(entry)
                let id = Bundle(url: url)?.bundleIdentifier
                if let id, config.ignore.contains(id) { continue }
                let name = (fm.displayName(atPath: url.path) as NSString).deletingPathExtension
                out.append((url, name, id, NSWorkspace.shared.icon(forFile: url.path)))
            }
        }
        out.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        appCache = (out, Date())
        return out
    }

    private func pickerMap() -> Picker.Map {
        let frames = world.frames(inner: config.inner, outer: config.outer)
        let windows = world.tiled.compactMap { id -> (id: WindowID, frame: CGRect, app: String, title: String, icon: NSImage?)? in
            guard let f = frames[id] else { return nil }
            let app = infos[id].flatMap { workers[$0.pid]?.app }
            return (id, f, app?.localizedName ?? "", infos[id]?.title ?? "", app?.icon)
        }
        return Picker.Map(monitors: world.monitors.map(\.frame), windows: windows, labels: world.labels(Picker.alphabet))
    }

    // MARK: Rescue from the menu

    func menuRescue() { toast("rescued \(rescue()) windows") }
    func menuRetile() { _ = run([.retile]) }
    func menuPause() { _ = run([.pause]) }
    func menuReload() { _ = run([.reload]) }

    // MARK: tess tree

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
                        + (mon.fullscreen == id ? " fullscreen" : ""))
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
