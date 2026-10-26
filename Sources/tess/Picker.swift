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
    }

    /// Step 2's picture: monitors and tiled windows in AX coordinates.
    struct Map {
        var monitors: [CGRect]
        var windows: [(id: WindowID, frame: CGRect, app: String, title: String, icon: NSImage?)]
        var labels: [WindowID: Character]
    }

    static let alphabet = "asdhjklqwertyuiopzxcvbnm"
    /// `f name` searches file names, `rg text` file contents; results come from `search`.
    static let searchVerbs: Set<String> = ["f", "rg", "book", "paper"]

    var onDone: (Item, Choice) -> Void = { _, _ in }
    var onCancel: () -> Void = {}
    var search: (_ verb: String, _ query: String, _ done: @escaping ([Item]) -> Void) -> Void = { _, _, _ in }
    private var searchGeneration = 0

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
    private var mapModel: () -> Map = { Map(monitors: [], windows: [], labels: [:]) }
    private var screen = CGRect.zero
    private var monitor: Any?
    private var picked: Item?
    private var verbs: [String: String] = [:]

    override init() {
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
        glass.contentView = content
        panel.contentView = glass

        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        magnifier.contentTintColor = .secondaryLabelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.placeholderString = "Window, tab or app"
        field.delegate = self
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        footer.font = .systemFont(ofSize: 11, weight: .medium)
        footer.textColor = .tertiaryLabelColor
        footer.alignment = .center
        for v in [magnifier, field, divider, list, map, footer] as [NSView] { content.addSubview(v) }
    }

    var isOpen: Bool { panel.isVisible }

    /// Shows step 1 on `screen`. With `fixed`, a pick goes straight there (no step 2).
    func open(_ items: [Item], on screen: CGRect, fixed: Spot?, verbs: [String: String], text: String = "",
              map: @escaping () -> Map) {
        self.items = items
        self.verbs = verbs
        self.fixed = fixed
        self.screen = screen
        mapModel = map
        field.stringValue = text
        picked = nil
        filter()
        showList()
        // A quick fade and a slight scale-in.
        let final = panel.frame
        panel.setFrame(final.insetBy(dx: final.width * 0.015, dy: final.height * 0.015), display: false)
        panel.alphaValue = 0
        // tess becomes the active app while the picker is open: a background app (a terminal,
        // a notification) can then not take the keyboard from it and cancel it.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        field.currentEditor()?.moveToEndOfDocument(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) ?? e }
        Log.write("picker: open on \(screen), panel \(final), key \(panel.isKeyWindow)")
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
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panel.orderOut(nil)
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
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        let words = field.stringValue.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if words.count == 2, Self.searchVerbs.contains(words[0]) {
            searchGeneration += 1
            let generation = searchGeneration
            let query = words[1].trimmingCharacters(in: .whitespaces)
            shown = []
            list.items = []
            let hint = ["f": "Type part of a file name", "rg": "Type text to find in files",
                        "book": "Type a title and an author's surname",
                        "paper": "Type a title and an author's surname (arXiv first)"][words[0]] ?? ""
            list.empty = query.isEmpty ? hint : "Searching…"
            list.needsDisplay = true
            guard !query.isEmpty else { return }
            // Wait for a pause in typing, and drop answers to older queries.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, generation == self.searchGeneration else { return }
                self.search(words[0], query) { [weak self] found in
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
        shown = items.enumerated()
            .filter { !$0.element.quiet || !q.isEmpty }
            .compactMap { i, item in fuzzyScore(q, item.search).map { (score: $0, i: i, item: item) } }
            .sorted { ($0.score, -$0.i) > ($1.score, -$1.i) }
            .map(\.item)
        list.items = shown
        list.query = q
        list.selected = 0
        list.needsDisplay = true
    }

    /// `verb path`: the folders the path could mean, the typed one first when it exists.
    private func folders(_ text: String) -> [Item]? {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let app = verbs[parts[0]] else { return nil }
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
        let size = NSSize(width: 680, height: 66 + rows * ListView.row + 12 + 26)
        place(size)
        magnifier.frame = NSRect(x: 22, y: size.height - 47, width: 22, height: 22)
        field.frame = NSRect(x: 54, y: size.height - 50, width: size.width - 76, height: 30)
        divider.frame = NSRect(x: 0, y: size.height - 66, width: size.width, height: 1)
        list.frame = NSRect(x: 10, y: 34, width: size.width - 20, height: rows * ListView.row)
        footer.frame = NSRect(x: 0, y: 9, width: size.width, height: 16)
        footer.stringValue = fixed == nil
            ? "↵ pick, then where     ⌃N ⌃P move     cd / code + folder (⇥ completes)     f name     rg text     book / paper title     esc close"
            : "↵ fill the empty place      ⌃N ⌃P move      esc leave it empty"
        for v in [magnifier, field, divider, list] as [NSView] { v.isHidden = false }
        map.isHidden = true
        panel.makeFirstResponder(field)
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
        let model = mapModel()
        if case .window(let id) = item.kind { map.picked = id } else { map.picked = nil }
        map.model = model
        map.title = item.title
        map.icon = item.icon
        let size = NSSize(width: 1000, height: 580)
        place(size)
        map.frame = NSRect(x: 0, y: 30, width: size.width, height: size.height - 30)
        footer.frame = NSRect(x: 0, y: 9, width: size.width, height: 16)
        footer.stringValue = "letter  swap with it      ⌥ letter  beside it      ↵ here      1–\(max(model.monitors.count, 1))  that screen      g  just go      f  float      esc  back"
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
        let ctrl = e.modifierFlags.contains(.control)
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        // esc, or the key that opened the picker (any Hyper key), closes it.
        let hyper = e.modifierFlags.isSuperset(of: [.command, .option, .control, .shift])
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
                close()
                onDone(item, c)
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
        case (48, _, _):  // tab completes a folder
            guard shown.indices.contains(list.selected), case .open = shown[list.selected].kind,
                  let verb = field.stringValue.split(separator: " ").first else { return nil }
            field.stringValue = "\(verb) \(shown[list.selected].title)/"
            field.currentEditor()?.moveToEndOfDocument(nil)
            filter()
        case (125, _, _), (_, true, "n"), (_, true, "j"): list.move(1)
        case (126, _, _), (_, true, "p"), (_, true, "k"): list.move(-1)
        case (36, _, _), (76, _, _):
            guard shown.indices.contains(list.selected) else { return nil }
            let item = shown[list.selected]
            if let fixed {
                close()
                onDone(item, .place(fixed))
            } else {
                showMap(for: item)
            }
        default: return e
        }
        return nil
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Step 1's rows: icon, title (matched letters in the accent color), and what it is.
final class ListView: NSView {
    static let visible = 10
    static let row: CGFloat = 38
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
                NSBezierPath(roundedRect: bg, xRadius: 9, yRadius: 9).fill()
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: bg.minX + 4, y: bg.minY + 8, width: 3, height: bg.height - 16),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }
            item.icon?.draw(in: NSRect(x: 16, y: r.minY + 7, width: 24, height: 24))
            let detailAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let detail = item.detail as NSString
            let dw = min(detail.size(withAttributes: detailAttrs).width, bounds.width * 0.42)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingMiddle
            detail.draw(in: NSRect(x: r.maxX - dw - 14, y: r.minY + 12, width: dw, height: 16),
                        withAttributes: detailAttrs.merging([.paragraphStyle: style]) { $1 })
            title(item.title).draw(in: NSRect(x: 50, y: r.minY + 10, width: r.width - 50 - dw - 30, height: 20))
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
        for (n, m) in model.monitors.enumerated() {
            let box = mini(m).insetBy(dx: 5, dy: 5)
            let path = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            path.lineWidth = 1
            path.stroke()
            ("\(n + 1)" as NSString).draw(at: NSPoint(x: box.maxX - 14, y: box.minY - 20), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        }
        for w in model.windows {
            let r = mini(w.frame).insetBy(dx: 4, dy: 4)
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
                    keycap(label, NSRect(x: x, y: r.midY - side / 2, width: side, height: side))
                    x += side + 6
                }
                let icon = min(18, r.height - 6)
                w.icon?.draw(in: NSRect(x: x, y: r.midY - icon / 2, width: icon, height: icon))
                x += icon + 6
                let line = NSMutableAttributedString(string: w.app, attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor,
                ])
                if !w.title.isEmpty {
                    line.append(NSAttributedString(string: "  \(w.title)", attributes: [
                        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
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
                (w.title as NSString).draw(in: NSRect(x: r.minX + 8, y: iconRect.maxY + 22, width: r.width - 16, height: 15), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: clip,
                ])
                if let label { keycap(label, NSRect(x: r.minX + 9, y: r.minY + 9, width: 28, height: 28)) }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func keycap(_ label: Character, _ cap: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: cap, xRadius: cap.height / 4, yRadius: cap.height / 4).fill()
        let text = String(label).uppercased() as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: cap.height * 0.55, weight: .bold), .foregroundColor: NSColor.white]
        let s = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: cap.midX - s.width / 2, y: cap.midY - s.height / 2), withAttributes: attrs)
    }
}
