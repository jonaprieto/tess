import AppKit
import Layout

/// The picker: step 1 picks what (a window, a browser tab, an app) from a filtered list,
/// step 2 picks where on a map of every monitor. Keyboard only; a click elsewhere cancels.
final class Picker: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    enum Kind {
        case window(WindowID)
        case tab(Tab)
        case app(URL)
        /// A folder to open with an app, from a verb like `cd ~/anoma`.
        case open(app: String, path: String)
        /// A page from browser history or bookmarks, opened with that browser.
        case url(URL, browser: String)
        /// A file found by name (`f`), opened with its app.
        case file(String)
        /// A line found by content (`rg`), opened in the editor at that line.
        case match(String, line: Int)
        /// A book or paper found with folio (`book`, `paper`), downloaded and then opened.
        case book(md5: String)
        /// An open-access PDF (arXiv, from `paper`), downloaded as `name` and then opened.
        case pdf(URL, name: String)
        /// The calculator's result, copied.
        case copy(String)
        /// Sleep, lock, or a loginwindow event (log out, restart, shut down) by its code.
        case system(String)
        /// tess commands, as the CLI and the config take them.
        case command([Command])
        /// Text typed into an app after a shortcut, from a `keys:` verb (`slack michael`).
        case keys(KeysVerb, text: String)
        /// A shell line run in the terminal app, from a `run:` verb (`brew install fzf`).
        case run(String)
        /// One of the person's Shortcuts, by name, run as it is.
        case shortcut(String)

        /// The file, folder or app it is, for cmd-enter.
        var path: String? {
            switch self {
            case .app(let url): url.path
            case .open(_, let path), .file(let path), .match(let path, _): path
            default: nil
            }
        }
    }

    struct Tab {
        var bundleID: String
        var window: Int
        var index: Int
    }

    struct Item {
        var kind: Kind
        var title: String
        var detail: String
        var icon: NSImage?
        /// What typing matches against.
        var search: String
        /// Only listed once something is typed (browser history: too much for an empty query).
        var quiet = false
    }

    enum Choice {
        case place(Spot)
        case jump
        /// cmd-enter: the file, folder or app shown in Finder instead of opened.
        case reveal
    }

    /// Step 2's picture: monitors and tiled windows in AX coordinates.
    struct Map {
        var monitors: [CGRect]
        var windows: [(id: WindowID, frame: CGRect, app: String, title: String, icon: NSImage?)]
        var labels: [WindowID: Character]
        var replaceWarnings: [WindowID: String] = [:]
        var besideWarnings: [WindowID: String] = [:]
        var monitorWarnings: [Int: String] = [:]
        var hereWarning: String?
    }

    static let alphabet = labelAlphabet
    /// `f name` searches file names, `rg text` file contents; results come from `search`.

    var onDone: (Item, Choice) -> Void = { _, _ in }
    var onCancel: () -> Void = {}
    var search: (_ kind: PickerSearch, _ query: String, _ done: @escaping ([Item]) -> Void) -> Void = { _, _, _ in }
    private var searchGeneration = 0
    /// Which of the candidates the typed text means (Jev, with the config's `jev`): their index.
    var suggest: ((_ typed: String, _ candidates: [Item], _ done: @escaping (Int?) -> Void) -> Void)?
    private var jevAsked: (String, Int)?

    private let panel: KeyPanel
    private let content = NSView()
    private let magnifier = NSImageView()
    private let field = NSTextField()
    private let divider = NSView()
    private let list = ListView()
    private let map = MapView()
    private let footer = NSTextField(labelWithString: "")
    private var items: [Item] = []
    private var shown: [Item] = []
    private var fixed: Spot?
    private var mapModel: (Item) -> Map = { _ in Map(monitors: [], windows: [], labels: [:]) }
    private var screen = CGRect.zero
    private var monitor: Any?
    private var picked: Item?
    private var verbs: [String: String] = [:]
    private let defaults: UserDefaults?
    private(set) var recentQueries: [String]

    func completion(for text: String) -> String? {
        let prefix = text.lowercased()
        return recentQueries.first { $0.lowercased().hasPrefix(prefix) && $0.lowercased() != prefix }
    }
    // nil means the picker consumed the key; only a released picker passes it through.
    lazy var keyMonitor: (NSEvent) -> NSEvent? = { [weak self] event in
        guard let self else { return event }
        return self.key(event)
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        recentQueries = Array((defaults?.stringArray(forKey: "pickerRecentQueries") ?? []).prefix(100))
        panel = KeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        let glass = NSGlassEffectView()
        glass.cornerRadius = 20
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 20
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        glass.contentView = content
        panel.contentView = glass

        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        magnifier.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.placeholderString = "Window, tab or app"
        field.setAccessibilityLabel("Search windows, tabs, apps or commands")
        field.delegate = self
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        footer.font = .systemFont(ofSize: 12)
        footer.textColor = .secondaryLabelColor
        footer.alignment = .center
        footer.lineBreakMode = .byTruncatingMiddle
        for v in [magnifier, field, divider, list, map, footer] as [NSView] { content.addSubview(v) }
    }

    var isOpen: Bool { panel.isVisible }

    /// Shows step 1 on `screen`. With `fixed`, a pick goes straight there (no step 2).
    func open(_ items: [Item], on screen: CGRect, fixed: Spot?, verbs: [String: String], text: String = "",
              map: @escaping (Item) -> Map) {
        self.items = items
        self.verbs = verbs
        self.fixed = fixed
        self.screen = screen
        mapModel = map
        field.stringValue = text
        picked = nil
        jevAsked = nil
        filter()
        showList()
        // Resizing the glass during entry clips the fixed-size content and distorts its corners.
        panel.alphaValue = 0
        // tess becomes the active app while the picker is open: a background app (a terminal,
        // a notification) can then not take the keyboard from it and cancel it.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.moveToEndOfDocument(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: keyMonitor)
        Log.write("picker: open on \(screen), panel \(panel.frame), key \(panel.isKeyWindow)")
    }

    /// Tabs arrive after the panel is up; they go after the windows, before the apps.
    func add(_ more: [Item]) {
        guard isOpen else { return }
        let apps = items.firstIndex {
            if case .app = $0.kind { return true }
            return false
        }
        items.insert(contentsOf: more, at: apps ?? items.count)
        guard picked == nil else { return }
        // Keep the row the user is on: a late batch must not move Enter onto another item.
        let current = shown.indices.contains(list.selected) ? shown[list.selected] : nil
        filter()
        if let current, let i = shown.firstIndex(where: { $0.title == current.title && $0.detail == current.detail }) {
            list.selected = i
            list.move(0)
        }
        updateCompletion()
    }

    func close() {
        searchGeneration += 1
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.orderOut(nil)
        items = []
        shown = []
        list.items = []
        picked = nil
        map.model = Map(monitors: [], windows: [], labels: [:])
        map.icon = nil
        mapModel = { _ in Map(monitors: [], windows: [], labels: [:]) }
        jevAsked = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard isOpen else { return }
        let to = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        Log.write("picker: lost focus to \(to), closing")
        Events.record("picker.close", ["why": "lost focus", "to": to])
        close()
        onCancel()
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    // MARK: Step 1

    private func filter() {
        defer { updateCompletion() }
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        let words = field.stringValue.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if words.count == 2, verbs[words[0]].flatMap(PickerSearch.init(verb:)) == .history {
            pages(words[1].trimmingCharacters(in: .whitespaces))
            return
        }
        if words.count == 2, let kind = verbs[words[0]].flatMap(PickerSearch.init(verb:)) {
            searchGeneration += 1
            let generation = searchGeneration
            let query = words[1].trimmingCharacters(in: .whitespaces)
            shown = []
            list.items = []
            let hint = switch kind {
            case .files: "Type part of a file name"
            case .text: "Type text to find in files"
            case .books: "Type a title and an author's surname"
            case .papers: "Type a title and an author's surname (arXiv first)"
            case .history: ""
            }
            list.empty = query.isEmpty ? hint : "Searching…"
            list.needsDisplay = true
            guard !query.isEmpty else { return }
            // Wait for a pause in typing, and drop answers to older queries.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, generation == self.searchGeneration, self.isOpen else { return }
                self.search(kind, query) { [weak self] found in
                    guard let self, generation == self.searchGeneration, self.isOpen else { return }
                    self.shown = found
                    self.list.items = found
                    self.list.empty = "Nothing found"
                    self.list.selected = 0
                    self.list.needsDisplay = true
                }
            }
            return
        }
        list.empty = "Nothing matches"
        if let folders = folders(field.stringValue) {
            shown = folders
            list.items = shown
            list.query = ""
            list.selected = 0
            list.needsDisplay = true
            return
        }
        // Bookmarks and history only under a `search:history` verb (`web`): they outnumber
        // and outscore the windows and apps that are usually wanted.
        shown = items.enumerated()
            .filter { i in
                if case .url = i.element.kind { return false }
                return !i.element.quiet || !q.isEmpty
            }
            .compactMap { i, item in fuzzyWords(q, item.search).map { (score: $0, i: i, item: item) } }
            .sorted { ($0.score, -$0.i) > ($1.score, -$1.i) }
            .map(\.item)
        // A tess command as the CLI takes it (`move-to-screen 2`, `resize width +100`) on top,
        // instead of its plain listing.
        if let cs = try? Command.parse(q), Self.runnable(cs) {
            shown.removeAll { if case .command(let c) = $0.kind { return c == cs }; return false }
            shown.insert(Item(kind: .command(cs), title: Command.label(of: cs) ?? q, detail: "tess · \(q)",
                              icon: Icons.symbol("command"), search: ""), at: 0)
        }
        // A link verb's link on top, the rest still searched (`claude code` finds Claude Code too).
        if let l = link(q) ?? keys(q) ?? run(q) { shown.insert(l, at: 0) }
        // Arithmetic (not a lone number) is worked out on top.
        if Double(q) == nil, let v = Parse.arithmetic(q).map(Parse.number) {
            shown.insert(Item(kind: .copy(v), title: "= \(v)", detail: "Enter copies it",
                              icon: NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app"), search: ""), at: 0)
        }
        list.items = shown
        list.query = q
        list.selected = 0
        list.needsDisplay = true
        askJev(q)
    }

    /// After a pause in typing, Jev's pick among windows, tabs, commands and the apps that match
    /// best (never browser history) goes on top, unless the selection was moved meanwhile.
    private func askJev(_ q: String) {
        searchGeneration += 1
        let generation = searchGeneration
        // Not when the top row is already exact (a typed command, a sum), nor when the text
        // plainly names it, every word starting a word of its title (`activity` for Activity
        // Monitor): a guess must not bury what was typed.
        let typed = q.lowercased().split(separator: " ")
        let exact = shown.first.map { i -> Bool in
            switch i.kind {
            case .command, .copy: return true
            default:
                let words = i.title.lowercased().split { !$0.isLetter && !$0.isNumber }
                return typed.allSatisfy { w in words.contains { $0.hasPrefix(w) } }
            }
        } ?? false
        guard let suggest, q.count >= 3, !exact else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, generation == self.searchGeneration, self.isOpen else { return }
            func kind(_ i: Item) -> Int {
                switch i.kind {
                case .window, .tab: 0
                case .command, .system: 1
                case .app: 2
                default: 3
                }
            }
            // Late history adds no candidates: the same text is not asked twice.
            let pool = self.items.filter { kind($0) < 3 }
            guard self.jevAsked.map({ $0 != (q, pool.count) }) ?? true else { return }
            self.jevAsked = (q, pool.count)
            let candidates = Array(pool
                .sorted { a, b in
                    (kind(a), -(fuzzyWords(q, a.search) ?? -1)) < (kind(b), -(fuzzyWords(q, b.search) ?? -1))
                }
                .prefix(200))
            suggest(q, candidates) { [weak self] i in
                guard let self, generation == self.searchGeneration, self.isOpen, self.list.selected == 0, let i else { return }
                let pick = candidates[i]
                let same = { (x: Item) in x.title == pick.title && x.detail == pick.detail }
                guard !(self.shown.first.map(same) ?? false) else { return }
                self.shown.removeAll(where: same)
                self.shown.insert(pick, at: 0)
                self.list.items = self.shown
                self.list.selected = 0
                self.list.needsDisplay = true
            }
        }
    }

    /// Commands the picker runs: not itself, and not those that only print (tree, state).
    static func runnable(_ commands: [Command]) -> Bool {
        commands.allSatisfy { c in
            if case .pick = c { return false }
            return c.label != nil
        }
    }

    /// `verb text` for a link verb: the link with the text, opened by the app that handles it.
    private func link(_ text: String) -> Item? {
        let parts = text.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let template = verbs[parts[0]], !template.hasPrefix("run:"),
              let url = Parse.link(template, parts[1]),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url), let bundle = Bundle(url: app)?.bundleIdentifier
        else { return nil }
        return Item(kind: .url(url, browser: bundle), title: parts[1], detail: "\(parts[0]) · \(url.host ?? "")",
                    icon: NSWorkspace.shared.icon(forFile: app.path), search: "")
    }

    /// A `search:history` verb: only the browsers' tabs, bookmarks and history, and the text
    /// itself on top when it is an address.
    private func pages(_ query: String) {
        shown = items.enumerated()
            .filter { _, item in
                switch item.kind {
                case .url, .tab: true
                default: false
                }
            }
            .compactMap { i, item in fuzzyWords(query, item.search).map { (score: $0, i: i, item: item) } }
            .sorted { ($0.score, -$0.i) > ($1.score, -$1.i) }
            .map(\.item)
        if let url = Parse.address(query), let app = NSWorkspace.shared.urlForApplication(toOpen: url),
           let browser = Bundle(url: app)?.bundleIdentifier {
            shown.insert(Item(kind: .url(url, browser: browser), title: url.absoluteString, detail: "open",
                              icon: NSWorkspace.shared.icon(forFile: app.path), search: ""), at: 0)
        }
        list.items = shown
        list.query = query
        list.empty = query.isEmpty ? "Type part of a page's title or address, or an address to open" : "Nothing matches"
        list.selected = 0
        list.needsDisplay = true
    }

    /// `verb text` for a `run:` verb: the command it makes, to run in a terminal.
    private func run(_ text: String) -> Item? {
        let parts = text.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let line = verbs[parts[0]].flatMap({ Parse.run($0, parts[1]) }) else { return nil }
        return Item(kind: .run(line), title: line, detail: "\(parts[0]) · runs in the terminal",
                    icon: Icons.symbol("terminal"), search: "")
    }

    /// `verb text` for a `keys:` verb: that app, the shortcut, then the text.
    private func keys(_ text: String) -> Item? {
        let parts = text.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let k = verbs[parts[0]].flatMap(KeysVerb.init(verb:)) else { return nil }
        let icon = items.first { if case .app = $0.kind { return $0.title == k.app }; return false }?.icon
        return Item(kind: .keys(k, text: parts[1]), title: parts[1], detail: "\(parts[0]) · \(k.app) \(k.key.symbol)",
                    icon: icon ?? Icons.symbol("keyboard"), search: "")
    }

    /// `verb path`: the folders the path could mean, the typed one first when it exists.
    private func folders(_ text: String) -> [Item]? {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let app = verbs[parts[0]], !app.contains("%s"), KeysVerb(verb: app) == nil,
              PickerSearch(verb: app) == nil else { return nil }
        let typed = parts[1]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = typed.isEmpty ? home + "/" : (typed as NSString).expandingTildeInPath + (typed.hasSuffix("/") ? "/" : "")
        let base = path.hasSuffix("/") ? String(path.dropLast()) : (path as NSString).deletingLastPathComponent
        let prefix = path.hasSuffix("/") ? "" : (path as NSString).lastPathComponent
        func isDir(_ p: String) -> Bool {
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: p, isDirectory: &d) && d.boolValue
        }
        func item(_ p: String) -> Item {
            let shown = p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
            return Item(kind: .open(app: app, path: p), title: shown.isEmpty ? "~" : shown, detail: "open in \(app)",
                        icon: NSWorkspace.shared.icon(forFile: p), search: "")
        }
        var out: [Item] = []
        let exact = path.hasSuffix("/") ? String(path.dropLast()) : path
        if !typed.isEmpty, isDir(exact) { out.append(item(exact)) }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: base.isEmpty ? "/" : base)) ?? []).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        for name in names where name.lowercased().hasPrefix(prefix.lowercased()) && (!name.hasPrefix(".") || prefix.hasPrefix(".")) {
            let full = (base.isEmpty ? "" : base) + "/" + name
            if full != exact, isDir(full) { out.append(item(full)) }
            if out.count >= 60 { break }
        }
        return out
    }

    private func showList() {
        let rows = CGFloat(ListView.visible)
        let size = NSSize(width: 680, height: 64 + 12 + rows * ListView.row + 44)
        place(size)
        magnifier.frame = NSRect(x: 24, y: size.height - 43, width: 22, height: 22)
        field.frame = NSRect(x: 56, y: size.height - 46, width: size.width - 80, height: 28)
        divider.frame = NSRect(x: 24, y: size.height - 64, width: size.width - 48, height: 1)
        list.frame = NSRect(x: 12, y: 44, width: size.width - 24, height: rows * ListView.row)
        footer.frame = NSRect(x: 24, y: 12, width: size.width - 48, height: 18)
        updateCompletion()
        for v in [magnifier, field, divider, list] as [NSView] { v.isHidden = false }
        map.isHidden = true
        panel.makeFirstResponder(field)
    }

    private func updateCompletion() {
        guard picked == nil else { return }
        if shown.indices.contains(list.selected), case .open = shown[list.selected].kind {
            footer.stringValue = "⇥ complete folder: \(shown[list.selected].title)"
            return
        }
        if let query = completion(for: field.stringValue) {
            footer.stringValue = "⇥ complete: \(query)"
            return
        }
        footer.stringValue = fixed == nil
            ? "↵ Choose     ⌘↵ Reveal in Finder     ↑↓ Navigate     ⇥ Complete     Esc Close"
            : "↵ Fill this place     ↑↓ Navigate     ⇥ Complete     Esc Leave empty"
    }

    private func finish(_ item: Item, _ choice: Choice) {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            recentQueries.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
            recentQueries.insert(query, at: 0)
            recentQueries = Array(recentQueries.prefix(100))
            defaults?.set(recentQueries, forKey: "pickerRecentQueries")
        }
        close()
        onDone(item, choice)
    }

    // MARK: Step 2

    /// The map as a PNG, drawn offscreen in dark appearance on a dark background.
    static func render(_ model: Map, size: NSSize) -> Data? {
        let view = MapView(frame: NSRect(origin: .zero, size: size))
        view.model = model
        view.title = "Example"
        let image = NSImage(size: size, flipped: true) { rect in
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                NSColor(white: 0.16, alpha: 1).setFill()
                rect.fill()
                view.draw(rect)
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func showMap(for item: Item) {
        picked = item
        let model = mapModel(item)
        if case .window(let id) = item.kind { map.picked = id } else { map.picked = nil }
        map.model = model
        map.title = item.title
        map.icon = item.icon
        let size = NSSize(width: 1000, height: 580)
        place(size)
        map.frame = NSRect(x: 0, y: 44, width: size.width, height: size.height - 44)
        footer.frame = NSRect(x: 24, y: 12, width: size.width - 48, height: 18)
        // A screen to choose only when there is a choice.
        let screens = model.monitors.count
        footer.stringValue = "Letter Swap     ⌥ Letter Beside     ↵ Here\(screens > 1 ? "     1–\(screens) Screen" : "")     G Go     F Float     Esc Back"
        if let warning = model.hereWarning {
            footer.stringValue = "↵ here: ⚠ \(warning) may not fit      letter swap      ⌥ letter beside\(screens > 1 ? "      number screen" : "")      g go      f float      esc back"
        }
        for v in [magnifier, field, divider, list] as [NSView] { v.isHidden = true }
        map.isHidden = false
        map.needsDisplay = true
        panel.makeFirstResponder(nil)
    }

    private func place(_ size: NSSize) {
        let r = CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        panel.setFrame(Screens.flip(r), display: true)
    }

    // MARK: Keys

    private func key(_ e: NSEvent) -> NSEvent? {
        defer { updateCompletion() }
        let ctrl = e.modifierFlags.contains(.control)
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        // Esc or a picker shortcut closes it.
        let modifiers = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let hyper = e.modifierFlags.isSuperset(of: [.command, .option, .control, .shift])
            || (e.keyCode == 49 && (modifiers == .option || modifiers == .command))
        if e.keyCode == 53 || hyper {
            if picked != nil, fixed == nil, !hyper {
                picked = nil
                showList()
            } else {
                close()
                onCancel()
            }
            return nil
        }
        if let item = picked {
            let model = map.model
            func done(_ c: Choice) {
                finish(item, c)
            }
            switch ch {
            case "\r": done(.place(.here))
            case "g": done(.jump)
            case "f": done(.place(.float))
            default:
                if let n = Int(ch), n >= 1, n <= model.monitors.count {
                    done(.place(.monitor(n - 1)))
                } else if let c = ch.first, let id = model.labels.first(where: { $0.value == c })?.key {
                    // A letter or ⇧ letter swaps, as in jump mode; ⌥ letter goes beside it.
                    done(.place(e.modifierFlags.contains(.option) ? .beside(id) : .replace(id)))
                }
            }
            return nil
        }
        switch (e.keyCode, ctrl, ch) {
        case (48, _, _):
            if shown.indices.contains(list.selected), case .open = shown[list.selected].kind,
               let verb = field.stringValue.split(separator: " ").first {
                field.stringValue = "\(verb) \(shown[list.selected].title)/"
            } else if let query = completion(for: field.stringValue) {
                field.stringValue = query
            } else { return nil }
            field.currentEditor()?.moveToEndOfDocument(nil)
            filter()
        case (125, _, _), (_, true, "n"), (_, true, "j"): list.move(1)
        case (126, _, _), (_, true, "p"), (_, true, "k"): list.move(-1)
        case (36, _, _), (76, _, _):
            guard shown.indices.contains(list.selected) else { return nil }
            let item = shown[list.selected]
            if e.modifierFlags.contains(.command), item.kind.path != nil {
                finish(item, .reveal)
                return nil
            }
            switch (item.kind, fixed) {
            case (.copy, _), (.system, _), (.command, _), (.keys, _), (.run, _), (.shortcut, _):
                finish(item, .place(.here))
            case (_, let fixed?):
                finish(item, .place(fixed))
            default:
                showMap(for: item)
            }
        default: return e
        }
        return nil
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // This accessory app has no Edit menu to route the field editor's shortcuts.
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           let editor = firstResponder as? NSTextView, editor.isEditable {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": editor.paste(nil)
            case "c": editor.copy(nil)
            case "x": editor.cut(nil)
            case "a": editor.selectAll(nil)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Step 1's rows: icon, title (matched letters in the accent color), and what it is.
final class ListView: NSView {
    static let visible = 8
    static let row: CGFloat = 44
    var items: [Picker.Item] = []
    var query = ""
    var empty = "Nothing matches"
    var selected = 0
    private var top = 0

    override var isFlipped: Bool { true }

    func move(_ by: Int) {
        guard !items.isEmpty else { return }
        selected = min(max(selected + by, 0), items.count - 1)
        if selected < top { top = selected }
        if selected >= top + Self.visible { top = selected - Self.visible + 1 }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected < top || selected >= top + Self.visible { top = max(0, selected - Self.visible + 1) }
        if items.isEmpty {
            (empty as NSString).draw(at: NSPoint(x: 16, y: 12), withAttributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            return
        }
        for (n, i) in (top..<min(items.count, top + Self.visible)).enumerated() {
            let item = items[i]
            let r = NSRect(x: 0, y: CGFloat(n) * Self.row, width: bounds.width, height: Self.row)
            if i == selected {
                let bg = r.insetBy(dx: 2, dy: 2)
                NSColor.labelColor.withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: bg.minX + 4, y: bg.minY + 8, width: 3, height: bg.height - 16),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }
            item.icon?.draw(in: NSRect(x: 12, y: r.midY - 12, width: 24, height: 24))
            let detailAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let detail = item.detail as NSString
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingMiddle
            detail.draw(in: NSRect(x: 44, y: r.minY + 24, width: r.width - 58, height: 16),
                        withAttributes: detailAttrs.merging([.paragraphStyle: style]) { $1 })
            title(item.title).draw(in: NSRect(x: 44, y: r.minY + (item.detail.isEmpty ? 12 : 5), width: r.width - 58, height: 20))
        }
    }

    private func title(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let s = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ])
        let chars = Array(text)
        for p in fuzzyPositions(query, text) ?? [] {
            // Character index to UTF-16 range.
            let start = String(chars[..<p]).utf16.count
            s.addAttributes([.foregroundColor: NSColor.controlAccentColor, .font: NSFont.systemFont(ofSize: 14, weight: .bold)],
                            range: NSRange(location: start, length: String(chars[p]).utf16.count))
        }
        return s
    }
}

/// Step 2: every monitor as arranged, each tiled window with its app icon and a keycap letter.
final class MapView: NSView {
    var model = Picker.Map(monitors: [], windows: [], labels: [:])
    var picked: WindowID?
    var title = ""
    var icon: NSImage?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: NSRect(x: 22, y: 18, width: 26, height: 26))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        ("Where should “\(title)” go?" as NSString).draw(in: NSRect(x: 56, y: 20, width: bounds.width - 80, height: 24), withAttributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ])
        guard let all = model.monitors.reduce(nil, { (u: CGRect?, r) in u?.union(r) ?? r }), all.width > 0 else { return }
        let area = NSRect(x: 22, y: 60, width: bounds.width - 44, height: bounds.height - 72)
        let scale = min(area.width / all.width, area.height / all.height)
        let offset = CGPoint(x: area.minX + (area.width - all.width * scale) / 2, y: area.minY + (area.height - all.height * scale) / 2)
        func mini(_ r: CGRect) -> CGRect {
            CGRect(x: offset.x + (r.minX - all.minX) * scale, y: offset.y + (r.minY - all.minY) * scale,
                   width: r.width * scale, height: r.height * scale)
        }
        let boxes = model.monitors.map { mini($0).insetBy(dx: 5, dy: 5) }
        for (n, box) in boxes.enumerated() {
            let warning = model.monitorWarnings[n]
            let path = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            // The screen's number key heads it, in the inverse of the window letters.
            if let digit = "\(n + 1)".first {
                Self.keycap(digit, NSRect(x: box.minX + 8, y: box.minY + 7, width: 24, height: 24), fill: warning == nil ? .labelColor : .systemOrange, text: .textBackgroundColor)
            }
            ((warning.map { "⚠ \($0) may not fit" } ?? "Screen \(n + 1)") as NSString).draw(in: NSRect(x: box.minX + 40, y: box.minY + 11, width: box.width - 48, height: 16), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        // A window inside its screen's box, below the header.
        func inScreen(_ r: CGRect) -> CGRect {
            guard let i = model.monitors.firstIndex(where: { $0.contains(CGPoint(x: r.midX, y: r.midY)) }) else { return mini(r) }
            let m = model.monitors[i], b = boxes[i]
            let inner = CGRect(x: b.minX + 2, y: b.minY + 36, width: b.width - 4, height: b.height - 38)
            return CGRect(x: inner.minX + (r.minX - m.minX) / m.width * inner.width,
                          y: inner.minY + (r.minY - m.minY) / m.height * inner.height,
                          width: r.width / m.width * inner.width, height: r.height / m.height * inner.height)
        }
        for w in model.windows {
            let warnings = [model.replaceWarnings[w.id].map { "swap: \($0)" },
                            model.besideWarnings[w.id].map { "beside: \($0)" }].compactMap { $0 }
            let warning = warnings.isEmpty ? nil : "⚠ " + warnings.joined(separator: "; ") + " may not fit"
            let caption = warning ?? w.title
            let capColor: NSColor = warning == nil ? Panels.accent : .systemOrange
            let r = inScreen(w.frame).insetBy(dx: 4, dy: 4)
            guard r.width > 4, r.height > 4 else { continue }
            let isPicked = w.id == picked
            let path = NSBezierPath(roundedRect: r, xRadius: min(9, r.height / 3), yRadius: min(9, r.height / 3))
            (isPicked ? NSColor.controlAccentColor.withAlphaComponent(0.35) : NSColor.labelColor.withAlphaComponent(0.1)).setFill()
            path.fill()
            (isPicked ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.18)).setStroke()
            path.lineWidth = isPicked ? 2 : 1
            path.stroke()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let clip = NSMutableParagraphStyle()
            clip.lineBreakMode = .byTruncatingTail
            let label = model.labels[w.id]
            if r.height < 72 {
                // A compact row: keycap, icon and "App · title" on one line.
                let side = min(24, r.height - 6)
                var x = r.minX + 6
                if let label {
                    Self.keycap(label, NSRect(x: x, y: r.midY - side / 2, width: side, height: side), fill: capColor)
                    x += side + 6
                }
                let icon = min(18, r.height - 6)
                w.icon?.draw(in: NSRect(x: x, y: r.midY - icon / 2, width: icon, height: icon))
                x += icon + 6
                let line = NSMutableAttributedString(string: w.app, attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor,
                ])
                if !caption.isEmpty {
                    line.append(NSAttributedString(string: "  \(caption)", attributes: [
                        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: warning == nil ? NSColor.secondaryLabelColor : .systemOrange,
                    ]))
                }
                line.addAttribute(.paragraphStyle, value: clip, range: NSRange(location: 0, length: line.length))
                line.draw(in: NSRect(x: x, y: r.midY - 8, width: r.maxX - x - 6, height: 16))
            } else {
                let side = min(40, r.height * 0.35, r.width * 0.4)
                let iconRect = NSRect(x: r.midX - side / 2, y: r.midY - side / 2 - 12, width: side, height: side)
                w.icon?.draw(in: iconRect)
                clip.alignment = .center
                (w.app as NSString).draw(in: NSRect(x: r.minX + 8, y: iconRect.maxY + 6, width: r.width - 16, height: 16), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: clip,
                ])
                (caption as NSString).draw(in: NSRect(x: r.minX + 8, y: iconRect.maxY + 22, width: r.width - 16, height: 30), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: warning == nil ? NSColor.secondaryLabelColor : .systemOrange, .paragraphStyle: clip,
                ])
                if let label { Self.keycap(label, NSRect(x: r.minX + 9, y: r.minY + 9, width: 28, height: 28), fill: capColor) }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static func keycap(_ label: Character, _ cap: NSRect, fill: NSColor = .controlAccentColor, text color: NSColor = .white) {
        fill.setFill()
        NSBezierPath(roundedRect: cap, xRadius: cap.height / 4, yRadius: cap.height / 4).fill()
        let text = String(label).uppercased() as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: cap.height * 0.55, weight: .bold), .foregroundColor: color]
        let s = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: cap.midX - s.width / 2, y: cap.midY - s.height / 2), withAttributes: attrs)
    }
}
