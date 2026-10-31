import AppKit
import Layout

/// A change to the layout made with a key, the CLI, the menu or the picker.
struct Step {
    var title: String
    /// The window it was about.
    var detail: String
    var before: World
    var after: World
    var at: Date
}

/// The last ten changes, for undo and redo from the menu or `u` and `shift-u` in tess mode.
extension Tiler {
    /// Called after a change; the same change repeated within a few seconds (resizing step by
    /// step) is one step. Steps that were undone are dropped.
    func remember(_ title: String, _ detail: String, from before: World) {
        guard !world.sameLayout(as: before) else { return }
        history.removeLast(undone)
        undone = 0
        if let last = history.last, last.title == title, last.detail == detail, Date().timeIntervalSince(last.at) < 3 {
            history[history.count - 1].after = world
            history[history.count - 1].at = Date()
        } else {
            history.append(Step(title: title, detail: detail, before: before, after: world, at: Date()))
            if history.count > 10 { history.removeFirst(history.count - 10) }
        }
    }

    /// A step that is in effect is undone, with every step after it; one that was undone is
    /// redone, with every step before it.
    func revisit(_ i: Int) {
        guard history.indices.contains(i), !paused else { return }
        let undoing = i < history.count - undone
        let step = history[i]
        world = world.restoring(undoing ? step.before : step.after)
        undone = undoing ? history.count - i : history.count - i - 1
        writes = [:]
        Events.record(undoing ? "undo" : "redo", ["step": step.title, "layout": layoutJSON()])
        toast(undoing ? L("Undid: \(step.title)") : L("Redid: \(step.title)"))
        if let f = world.focused { focus(f) }
        scheduleApply()
        flashFocus()
    }

    func undo() -> String {
        let i = history.count - undone - 1
        guard i >= 0 else { return "error: \(L("nothing to undo"))" }
        revisit(i)
        return ""
    }

    func redo() -> String {
        guard undone > 0 else { return "error: \(L("nothing to redo"))" }
        revisit(history.count - undone)
        return ""
    }

    func appName(_ id: WindowID) -> String {
        infos[id].flatMap { workers[$0.pid]?.app.localizedName } ?? L("a window")
    }

    /// "Safari: GitHub" for a step's detail.
    func windowName(_ id: WindowID?) -> String {
        guard let id, let info = infos[id] else { return "" }
        let app = workers[info.pid]?.app.localizedName ?? ""
        let title = info.title.count > 40 ? info.title.prefix(39) + "…" : info.title
        return title.isEmpty || title == app ? app : "\(app): \(title)"
    }
}
