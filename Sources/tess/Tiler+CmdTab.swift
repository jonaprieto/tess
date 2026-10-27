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
                                     title: infos[id]?.title ?? "",
                                     detail: detail.joined(separator: " · "), label: letters[id])
            }
            // The window before this one, as macOS's goes to the app before; the first when
            // what is in front is not one of these.
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let inFront = infos[ids[0]]?.pid == front
            switcher.open(cards, selected: back ? cards.count - 1 : inFront ? min(1, cards.count - 1) : 0, on: lookedAtFrame)
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

    /// Every window tess knows, most recently focused first, then the rest in screen order.
    var recentWindows: [WindowID] {
        let all = labeledWindows
        return world.mru.filter(all.contains) + all.filter { !world.mru.contains($0) }
    }
}
