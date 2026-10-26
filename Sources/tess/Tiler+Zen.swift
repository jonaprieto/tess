import AppKit
import Layout

/// Zen: for 25 minutes the focused window fills its screen and a veil darkens the others, then
/// 5 minutes of break with the layout back and a lighter veil on every screen, until `zen` runs
/// again.
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

    /// The screen Zen keeps: the focused window's (tiled or floating), else the active one, so
    /// the veil never covers the window it is for.
    var zenMonitor: Int {
        if let f = world.focused, let p = world.locate(f) { return p.m }
        if let f = world.focused, let frame = infos[f]?.frame, let m = world.monitorIndex(for: frame) { return m }
        return world.activeMonitor
    }

    /// Working: the other screens, dark. Break: every screen, lighter, so it cannot go unnoticed
    /// and what was left open still reads.
    func refreshVeil() {
        guard zen != nil, !paused else { return veil.show([]) }
        let m = zenMonitor
        veil.show(world.monitors.indices.filter { !zenWorking || $0 != m }.map { world.monitors[$0].frame },
                  alpha: zenWorking ? 0.95 : 0.6)
    }
}

/// Dark, click-through panels over the screens Zen is not using, just above normal windows and
/// below tess's own labels and toasts. Clicking through one focuses what is under it, and Zen
/// follows.
final class Veil {
    private var panels: [NSPanel] = []

    func show(_ screens: [CGRect], alpha: CGFloat = 0.95) {
        while panels.count < screens.count {
            panels.append(Panels.overlay(level: NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)))
        }
        for (n, p) in panels.enumerated() {
            guard let screen = screens[safe: n] else {
                p.orderOut(nil)
                continue
            }
            p.backgroundColor = NSColor.black.withAlphaComponent(alpha)
            let frame = Screens.flip(screen)
            if p.frame != frame { p.setFrame(frame, display: true) }
            if !p.isVisible { p.orderFrontRegardless() }
        }
    }
}
