import AppKit
import Layout

/// show-all: every running app's window back in sight, and every screen laid out with them.
extension Tiler {
    /// Every running app with no window in sight gets what its Dock icon does; once each has a
    /// window, or after 6 s, the new windows go to the screens with the fewest, and every screen
    /// is laid out as columns, or a grid past three windows.
    func showAll() {
        let before = world
        let shown = Set((world.tiled + world.floating.sorted()).compactMap { offSpace.contains($0) ? nil : infos[$0]?.pid })
        let apps = windowlessApps(besides: shown)
        apps.forEach(reopen)
        layOutAll(waitingFor: apps.map(\.processIdentifier), from: before, until: Date().addingTimeInterval(6))
    }

    private func layOutAll(waitingFor pids: [pid_t], from before: World, until: Date) {
        let shown = Set((world.tiled + world.floating.sorted()).compactMap { offSpace.contains($0) ? nil : infos[$0]?.pid })
        let waiting = pids.filter { !shown.contains($0) }
        guard waiting.isEmpty || Date() >= until else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.layOutAll(waitingFor: pids, from: before, until: until)
            }
            return
        }
        let old = Set(before.tiled)
        for id in world.tiled where !old.contains(id) {
            world.place(id, .monitor(world.leastBusy(prefer: world.activeMonitor)))
        }
        for m in world.monitors.indices {
            world.activeMonitor = m
            world.arrange(world.monitors[m].windows.count > 3 ? .grid : .columns)
        }
        // Each app that came forward took focus; it goes back to where it was.
        if let f = before.focused, world.contains(f) { world.focused = f }
        remember(L("Show all apps"), windowName(world.focused), from: before)
        let n = world.tiled.count
        let apps = waiting.compactMap { NSRunningApplication(processIdentifier: $0)?.localizedName }.joined(separator: ", ")
        toast(waiting.isEmpty ? L("\(n) windows") : L("\(n) windows, none from \(apps)"))
        if let f = world.focused { focus(f) }
        scheduleApply()
    }
}
