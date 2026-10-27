import AppKit
import Layout

/// cmd-tab over windows rather than apps: most recently used first, each with its letter.
extension Tiler {
    func onCmdTab(_ key: CmdTab.Key) {
        switch key {
        case .open(let back):
            guard !paused, !starting else { return }
            if picker.isOpen {
                picker.close()
                pickerClosed(cancelled: true)
            }
            let ids = recentWindows
            guard !ids.isEmpty else { return }
            switcherLetters = stableLabels(switcherLetters, windows: ids, alphabet: labelAlphabet)
            let letters = switcherLetters
            let cards = ids.map { id in
                let worker = infos[id].flatMap { workers[$0.pid] }
                let app = worker?.app.localizedName ?? ""
                var detail: [String] = []
                if world.monitors.count > 1, let m = world.locate(id)?.m ?? infos[id].flatMap({ world.monitorIndex(for: $0.frame) }) {
                    detail.append("Screen \(m + 1)")
                }
                return Switcher.Card(id: id, icon: worker?.icon ?? worker?.app.icon, app: app,
                                     title: shortTitle(infos[id]?.title ?? "", app: app),
                                     detail: detail.joined(separator: " · "), label: letters[id])
            }
            // The window before this one, as macOS's goes to the app before; the first when
            // what is in front is not one of these.
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let inFront = infos[ids[0]]?.pid == front
            switcher.open(cards, selected: back ? cards.count - 1 : inFront ? min(1, cards.count - 1) : 0, on: lookedAtFrame)
            askShortTitles(ids)
        case .step(let back):
            switcher.step(back ? -1 : 1)
        case .letter(let code):
            guard let c = Hotkeys.codes.first(where: { $0.value == UInt32(code) })?.key.first,
                  let card = switcher.cards.first(where: { $0.label == c }) else { return }
            switcher.close()
            use(card.id, .jump)
        case .cancel:
            switcher.close()
        case .release:
            guard let id = switcher.pick else { return }
            switcher.close()
            use(id, .jump)
        }
    }

    /// What a card says under the app's name: Jev's pick of the title's parts once it has
    /// answered, else the parts as they are.
    func shortTitle(_ title: String, app: String) -> String {
        shortTitles[title] ?? titleParts(title, app: app).joined(separator: " · ")
    }

    /// Asks Jev about the titles of `ids` it has not been asked about, in one request; the
    /// cards change if they are still up when it answers, and the next cmd-tab has them.
    func askShortTitles(_ ids: [WindowID]) {
        guard config.jev else { return }
        var asked = Set<String>()
        let items = ids.compactMap { id -> (app: String, title: String, parts: [String])? in
            guard let title = infos[id]?.title, shortTitles[title] == nil, asked.insert(title).inserted else { return nil }
            let app = appName(id)
            let parts = titleParts(title, app: app)
            return parts.count > 1 ? (app, title, parts) : nil
        }
        guard !items.isEmpty else { return }
        Jev.titleParts(items) { [weak self] picks in
            guard let self else { return }
            // ponytail: one entry per title ever seen, dropped at 500; titles that change every
            // second (counters, spinners) would want an expiry instead.
            if self.shortTitles.count > 500 { self.shortTitles = [:] }
            self.shortTitles.merge(picks) { $1 }
            self.switcher.retitle { id in self.infos[id].flatMap { self.shortTitles[$0.title] } }
        }
    }

    /// Every window tess knows, most recently focused first, then the rest in screen order.
    var recentWindows: [WindowID] {
        let all = labeledWindows
        return world.mru.filter(all.contains) + all.filter { !world.mru.contains($0) }
    }
}
