import AppKit
import Layout

/// Click mode: everything that can be pressed in the focused window gets a label, one letter or
/// two; typing one presses it, esc leaves. Its letters are hotkeys only while it lasts.
extension Tiler {
    func startClick() {
        guard let id = osFocused ?? world.focused, let info = infos[id], let worker = workers[info.pid] else {
            return toast(L("no window to click in"))
        }
        worker.clickables(in: id) { [weak self] found in
            guard let self else { return }
            guard !found.isEmpty else { return self.toast(L("nothing to click")) }
            let labels = hintLabels(found.count, alphabet: labelAlphabet)
            self.clickTargets = zip(labels, found).map { ClickTarget(label: $0, frame: $1.frame, element: $1.element, pid: info.pid) }
            self.clickTyped = ""
            self.overlay.showHints(self.clickTargets.map { ($0.label, $0.frame) })
            var keys: [KeySpec: [Command]] = [KeySpec(key: "esc", mods: []): [.clickKey("esc")]]
            for c in Set(labels.joined()) { keys[KeySpec(key: String(c), mods: [])] = [.clickKey(String(c))] }
            let failed = self.hotkeys.register(keys)
            if !failed.isEmpty { Log.write("click: could not register \(failed)") }
        }
    }

    func clickKey(_ k: String) {
        guard !clickTargets.isEmpty else { return }
        guard k != "esc" else { return endClick() }
        clickTyped += k
        let left = clickTargets.filter { $0.label.hasPrefix(clickTyped) }
        if let hit = left.first(where: { $0.label == clickTyped }) {
            endClick()
            workers[hit.pid]?.click(hit.element, at: hit.frame)
            return
        }
        // A key no label goes on with: start over.
        if left.isEmpty { clickTyped = "" }
        overlay.showHints((left.isEmpty ? clickTargets : left).map { ($0.label, $0.frame) }, typed: clickTyped)
    }

    func endClick() {
        clickTargets = []
        clickTyped = ""
        overlay.showHints([])
        registerMode()
    }
}

/// Something click mode labeled: its label, where it is, and the element to press.
struct ClickTarget {
    var label: String
    var frame: CGRect
    var element: AXUIElement
    var pid: pid_t
}
