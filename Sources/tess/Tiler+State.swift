import AppKit
import Layout

/// What tess knows, for the event log, tess state and tess tree.
extension Tiler {
    // MARK: tess tree

    // MARK: Event log

    // MARK: Event log

    /// A window for the log: id, app, title (cut at 200 characters) and frame.
    func describe(_ id: WindowID) -> [String: Any] {
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
    func layoutJSON() -> [String: Any] {
        ["focused": world.focused.map { Int($0) as Any } ?? NSNull(), "active_screen": world.activeMonitor + 1,
         "screens": world.monitors.enumerated().map { n, m in
            ["n": n + 1, "rows": m.rows, "fullscreen": m.fullscreen.map { Int($0) as Any } ?? NSNull(),
             "lanes": m.lanes.map { ["windows": $0.windows.map { Int($0) }, "accordion": $0.accordion] as [String: Any] }]
                as [String: Any] }]
    }


    /// Everything tess knows, and the machine it runs on.
    func stateJSON() -> [String: Any] {
        var state = layoutJSON()
        let frames = targets
        state["mode"] = mode
        state["zen"] = zenTitle ?? NSNull()
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


    func tree() -> String {
        func name(_ id: WindowID) -> String {
            guard let i = infos[id] else { return "\(id)" }
            let app = workers[i.pid]?.app.localizedName ?? "?"
            return "\(id) \(app): \(i.title)\(id == world.focused ? "  <- focused" : "")\(offSpace.contains(id) ? "  (other Space)" : "")"
        }
        let frames = targets
        var out = ["mode \(mode)\(paused ? " (paused)" : "")"]
        for (m, mon) in world.monitors.enumerated() {
            let f = mon.frame
            out.append("screen \(m + 1) \(mon.id.prefix(8)) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))"
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
