import AppKit
import Layout

/// The picker: what it lists, what a pick does, and its searches.
extension Tiler {
    // MARK: Picker

    // MARK: Picker

    func openPicker(fixed: Spot?, text: String = "") {
        guard !picking else { return }
        beginPicking()
        showPicker(fixed: fixed, text: text)
    }

    /// Jump mode is on: labels are keys until one is used; then back to `jumpReturn`.
    var jumping: Bool { mode == "jump" }


    func beginPicking() {
        focusBeforePicker = osFocused ?? world.focused
        picking = true
        hotkeys.unregisterAll()
        overlay.hideMode()
    }


    func showPicker(fixed: Spot?, text: String = "") {
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
        Browsers.history(config.history) { [weak self] pages in self?.picker.add(pages) }
    }


    func pickerClosed(cancelled: Bool) {
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


    func picked(_ item: Picker.Item, _ choice: Picker.Choice) {
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
        case .system("sleep"):
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = ["sleepnow"]
            try? p.run()
        case .system("lock"):
            // ponytail: login.framework's private SACLockScreenImmediate; if Apple drops it,
            // send ctrl-cmd-Q through System Events instead.
            if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
               let f = dlsym(h, "SACLockScreenImmediate") {
                _ = unsafeBitCast(f, to: (@convention(c) () -> Int32).self)()
            }
        case .system(let event):
            // loginwindow shows its own dialog before logging out, restarting or shutting down.
            Browsers.osascript("tell application \"loginwindow\" to «event aevt\(event)»") { _ in }
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            toast("copied \(text)")
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
            Proc.run("/bin/sh", ["-c", "folio get \"$1\"", "sh", md5], env: Proc.env, timeout: 600, log: "folio") { [weak self] out in
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
    func use(_ id: WindowID, _ choice: Picker.Choice) {
        let away = offSpace.contains(id) || infos[id] == nil
        if away, let pid = infos[id]?.pid ?? unseen[id] { NSRunningApplication(processIdentifier: pid)?.activate() }
        guard infos[id] != nil else {
            // Known only to the window server: place it once its app has listed it, if ever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                if self?.infos[id] != nil { self?.use(id, choice) }
            }
            return
        }
        if case .place(let spot) = choice {
            let before = world
            world.place(id, spot)
            remember("Put \(appName(id)) \(describe(spot))", windowName(id), from: before)
        } else if world.contains(id) {
            world.focused = id
        }
        if away {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.focus(id) }
        } else {
            focus(id)
        }
        scheduleApply()
        flashFocus(after: away ? 0.8 : 0.18)
    }


    /// Where a pick went, in words.
    func describe(_ spot: Spot) -> String {
        switch spot {
        case .replace(let t): "in place of \(appName(t))"
        case .beside(let t): "beside \(appName(t))"
        case .here: "here"
        case .monitor(let m): "on screen \(m + 1)"
        case .slot: "in the empty place"
        case .float: "floating"
        }
    }


    /// Opens a file with its default app; with a place, that app's next window goes there.
    func openFile(_ path: String, _ choice: Picker.Choice) {
        let url = URL(fileURLWithPath: path)
        if case .place(let spot) = choice, let app = NSWorkspace.shared.urlForApplication(toOpen: url),
           let b = Bundle(url: app)?.bundleIdentifier {
            pending = (b, spot, Date().addingTimeInterval(10))
        }
        NSWorkspace.shared.open(url)
    }


    /// arXiv's API for `query`: open-access papers, best match first.
    static func arxiv(_ query: String, _ done: @escaping ([Picker.Item]) -> Void) {
        let terms = Parse.arxivQuery(query)
        var c = URLComponents(string: "https://export.arxiv.org/api/query")!
        c.queryItems = [.init(name: "search_query", value: terms), .init(name: "max_results", value: "10")]
        guard let url = c.url else { return done([]) }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let items = Parse.arxiv(String(decoding: data ?? Data(), as: UTF8.self)).compactMap { p -> Picker.Item? in
                guard let pdf = p.pdf else { return nil }
                return Picker.Item(kind: .pdf(pdf, name: p.fileName), title: p.title, detail: p.detail,
                                   icon: NSWorkspace.shared.icon(for: .pdf), search: "")
            }
            DispatchQueue.main.async { done(items) }
        }.resume()
    }


    /// `f`: file names from Spotlight, ranked by fzf when it is installed. `rg`: file contents
    /// with ripgrep. Both under the home folder, in the background, the previous one stopped.
    func search(_ verb: String, _ query: String, _ done: @escaping ([Picker.Item]) -> Void) {
        Proc.stop(searchProcess)
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
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        searchProcess = Proc.run("/bin/sh", ["-c", script, "sh", query], env: Proc.env, timeout: 20) { output in
            let text = output ?? ""
            func short(_ path: String) -> String { Parse.short(path, home: home) }
            if verb == "book" || verb == "paper" {
                let books = Parse.folio(text).map { b in
                    Picker.Item(kind: .book(md5: b.md5), title: b.title, detail: b.detail,
                                icon: NSWorkspace.shared.icon(for: b.ext == "epub" ? .epub : .pdf), search: "")
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
                guard let m = Parse.rg(line) else { return nil }
                let path = home + "/" + m.path
                return Picker.Item(kind: .match(path, line: m.line), title: "\(short(path)):\(m.line)", detail: m.text,
                                   icon: NSWorkspace.shared.icon(forFile: path), search: "")
            }
            done(items)
        }
    }


    /// Windows (most recently focused first), then apps.
    func pickerItems() -> [Picker.Item] {
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
        let settings = NSWorkspace.shared.icon(forFile: "/System/Applications/System Settings.app")
        for (title, action) in [("Sleep", "sleep"), ("Lock Screen", "lock"), ("Log Out…", "logo"),
                                ("Restart…", "rrst"), ("Shut Down…", "rsdn")] {
            items.append(Picker.Item(kind: .system(action), title: title, detail: "system", icon: settings,
                                     search: title, quiet: true))
        }
        return items
    }


    /// Every app in the usual folders. Scanned off the main thread when tess starts and again
    /// every ten minutes, so opening the picker never waits for the disk.
    func apps() -> [(url: URL, name: String, bundleID: String?, icon: NSImage)] {
        if let c = appCache { return c.apps }
        let scanned = Self.scanApps(ignoring: config.ignore)
        appCache = (scanned, Date(), Self.appFolderDates())
        return scanned
    }


    /// Rescans only when an app folder changed (an app installed or removed).
    func refreshApps() {
        let ignore = config.ignore
        let previous = appCache
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let folders = Self.appFolderDates()
            let apps = previous.flatMap { $0.folders == folders ? $0.apps : nil } ?? Self.scanApps(ignoring: ignore)
            DispatchQueue.main.async { self?.appCache = (apps, Date(), folders) }
        }
    }


    static func appFolderDates() -> [Date] {
        appFolders.map { (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast }
    }


    static func scanApps(ignoring ignore: [String]) -> [(url: URL, name: String, bundleID: String?, icon: NSImage)] {
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


    func pickerMap() -> Picker.Map {
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
        // The same letters as on the windows themselves.
        let mapLabels = stableLabels(labels, windows: world.tiled, alphabet: labelAlphabet).filter { world.locate($0.key) != nil }
        return Picker.Map(monitors: world.monitors.map(\.frame), windows: windows, labels: mapLabels)
    }
}
