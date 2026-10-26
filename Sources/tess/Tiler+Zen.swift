import AppKit
import Layout

/// Zen: for 25 minutes the focused window fills its screen and a veil darkens the others, then
/// 5 minutes of break without either, until `zen` runs again.
extension Tiler {
    func toggleZen() {
        if zen == nil {
            zen = Pomodoro(start: Date())
            zenWorking = true
            let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.zenTick() }
            t.tolerance = 0.1
            zenTimer = t
            toast("zen: 25 min")
        } else {
            zen = nil
            zenWorking = false
            zenTimer?.invalidate()
            zenTimer = nil
            toast("zen off")
        }
        Events.record("zen", ["on": zen != nil])
        scheduleApply()
        onChange()
    }

    /// Once a second: the countdown in the menu bar, and the switch between work and break.
    func zenTick() {
        guard let working = zen?.phase(at: Date()).working else { return }
        if working != zenWorking {
            zenWorking = working
            NSSound(named: "Tink")?.play()
            toast(working ? "back to work" : "break, 5 min")
            Events.record("zen", ["working": working])
            scheduleApply()
        }
        onLayout()
    }

    /// "zen 24:13" or "break 4:02"; nil when Zen is off.
    var zenTitle: String? {
        guard let phase = zen?.phase(at: Date()) else { return nil }
        let left = Int(phase.left.rounded(.up))
        return String(format: "%@ %d:%02d", phase.working ? "zen" : "break", left / 60, left % 60)
    }

    func refreshVeil() {
        let m = world.activeMonitor
        veil.show(zenWorking && !paused ? world.monitors.indices.filter { $0 != m }.map { world.monitors[$0].frame } : [])
    }
}

/// Dark, click-through panels over the screens Zen is not using, just above normal windows and
/// below tess's own labels and toasts. Clicking through one focuses what is under it, and Zen
/// follows.
final class Veil {
    private var panels: [NSPanel] = []

    func show(_ screens: [CGRect]) {
        while panels.count < screens.count {
            let p = Panels.overlay(level: NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1))
            p.backgroundColor = NSColor.black.withAlphaComponent(0.95)
            panels.append(p)
        }
        for (n, p) in panels.enumerated() {
            guard let screen = screens[safe: n] else {
                p.orderOut(nil)
                continue
            }
            let frame = Screens.flip(screen)
            if p.frame != frame { p.setFrame(frame, display: true) }
            if !p.isVisible { p.orderFrontRegardless() }
        }
    }
}
