import AppKit
import Layout

/// Commands from hotkeys, the CLI and the menu.
extension Tiler {
    // MARK: Commands

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
        if !commands.contains(.undo), !commands.contains(.redo) {
            remember(Command.label(of: commands) ?? commands.map(\.description).joined(separator: "; "),
                     windowName(before.focused), from: before)
        }
        return out
    }


    func execute(_ c: Command) -> String {
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
                guard let self else { return }
                let before = self.world
                self.rebuild()
                self.remember("Re-tile", "", from: before)
                self.toast("re-tiled")
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
        case .jump: startJump()
        case .undo: return undo()
        case .redo: return redo()
        case .focusWindow(let id):
            guard infos[id] != nil else { return "error: no window \(id)" }
            use(id, .jump)
        case .swapWith(let id):
            guard let f = world.focused, f != id, world.locate(f) != nil, world.locate(id) != nil else {
                return "error: swap needs a focused tiled window and another tiled window"
            }
            world.swap(f, id)
            world.focused = f
            flash = true
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
        // A single cheat sheet follows to the screen being worked on.
        if mode != "main", !config.overlayAllScreens, world.activeMonitor != beforeMonitor,
           let m = world.monitors[safe: world.activeMonitor] {
            overlay.showMode(mode, config.modes[mode] ?? [:], on: [m.frame])
        }
        scheduleApply()
        return ""
    }


    /// Outlines the focused window (or the active monitor when it has none) once the move has
    /// landed: by then the window's own report says where it really is.
    func flashFocus(after delay: Double = 0.18) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // With labels always on, the focused window's border already says it.
            if self.config.windowLabels == .always, self.world.focused != nil { return }
            self.overlay.flash(self.world.focused.flatMap { self.infos[$0]?.frame } ?? self.activeFrame)
        }
    }


    func moveFloating(_ id: WindowID, to m: Int) {
        guard world.monitors.indices.contains(m), let info = infos[id] else { return }
        let target = CGRect.centered(info.frame.size, in: world.monitors[m].frame)
        workers[info.pid]?.setFrame(id, target)
        infos[id]?.frame = target
        world.activeMonitor = m
    }



    /// Every window showing less than a tenth of itself on any screen comes back: tiled ones
    /// get their frame written again, the rest are centered on the active monitor.
    func rescue() -> Int {
        var n = 0
        let screens = world.monitors.map(\.frame)
        for (id, info) in infos where info.standard && !offSpace.contains(id) {
            guard info.frame.isLost(on: screens) else { continue }
            n += 1
            if world.locate(id) != nil {
                writes[id] = nil
                infos[id]?.frame = .zero
            } else {
                let target = CGRect.centered(info.frame.size, in: activeFrame)
                workers[info.pid]?.setFrame(id, target)
                infos[id]?.frame = target
            }
        }
        Log.write("rescued \(n)")
        apply()
        return n
    }


    func setPaused(_ p: Bool) {
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


    // MARK: Rescue from the menu

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
}
