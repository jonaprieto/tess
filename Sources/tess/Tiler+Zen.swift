import AppKit
import Layout

/// Zen: for 25 minutes the focused window fills its screen and a veil
/// darkens the others, then 5 minutes of break with every screen
/// black and no key or click getting through, until `zen` runs again.
extension Tiler {
  /// A break now: Zen (turned on if it is off) from the start of its
  /// break, then work as usual.
  func takeBreak() {
    if zen == nil { toggleZen() }
    if let work = zen?.work {
      zen?.start = Date().addingTimeInterval(-work)
    }
    zenTick()
  }

  func toggleZen() {
    if zen == nil {
      zen = Pomodoro(start: Date())
      zenWorking = true
      let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true)
      { [weak self] _ in self?.zenTick() }
      t.tolerance = 0.1
      zenTimer = t
      toast("zen: 25 min")
    } else {
      zen = nil
      zenWorking = false
      zenTimer?.invalidate()
      zenTimer = nil
      toast(L("zen off"))
    }
    Events.record("zen", ["on": zen != nil])
    scheduleApply()
    onChange()
  }

  /// Once a second: the countdown in the menu bar, and the switch
  /// between work and break.
  func zenTick() {
    guard let working = zen?.phase(at: Date()).working else { return }
    if working != zenWorking {
      zenWorking = working
      if !working { countBreak() }
      NSSound(named: "Tink")?.play()
      toast(
        working
          ? L("back to work")
          : L("break, 5 min · \(breaksToday) today"))
      Events.record("zen", ["working": working])
      scheduleApply()
    }
    if !working { refreshVeil() }  // the time left on it
    onLayout()
  }

  /// Breaks begun today, kept by day across restarts.
  var breaksToday: Int {
    (UserDefaults.standard.dictionary(forKey: "breaks")
      as? [String: Int])?[Self.today] ?? 0
  }

  func countBreak() {
    var days =
      UserDefaults.standard.dictionary(forKey: "breaks")
      as? [String: Int] ?? [:]
    days[Self.today, default: 0] += 1
    UserDefaults.standard.set(days, forKey: "breaks")
  }

  /// The local date, 2026-10-27.
  static var today: String {
    let c = Calendar.current.dateComponents(
      [.year, .month, .day], from: Date())
    return String(
      format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }

  /// "zen 24:13" or "break 4:02"; nil when Zen is off.
  var zenTitle: String? {
    guard let phase = zen?.phase(at: Date()) else { return nil }
    let left = Int(phase.left.rounded(.up))
    return String(
      format: "%@ %d:%02d", phase.working ? "zen" : L("break"),
      left / 60, left % 60)
  }

  /// The screen Zen keeps: the focused window's (tiled or floating),
  /// else the active one, so the veil never covers the window it is
  /// for.
  var zenMonitor: Int {
    if let f = world.focused, let p = world.locate(f) { return p.m }
    if let f = world.focused, let frame = infos[f]?.frame,
      let m = world.monitorIndex(for: frame)
    {
      return m
    }
    return world.activeMonitor
  }

  /// Working: the other screens, dark. Break: every screen whole
  /// (menu bar and Dock too) black with the time left, and no key or
  /// click gets through until it ends.
  func refreshVeil() {
    let resting = zen != nil && !zenWorking && !paused
    CmdTab.block(resting)
    guard zen != nil, !paused else { return veil.show([]) }
    if resting {
      return veil.show(
        Screens.current().map(\.full), alpha: 1, level: .screenSaver,
        text: zenTitle)
    }
    let m = zenMonitor
    veil.show(
      world.monitors.indices.filter { $0 != m }.map {
        world.monitors[$0].frame
      })
  }
}

/// Dark, click-through panels over the screens Zen is not using, just
/// above normal windows and below tess's own labels and toasts.
/// Clicking through one focuses what is under it, and Zen follows. In
/// the break, over everything, with the time left in the middle.
final class Veil {
  private var panels: [(panel: NSPanel, text: NSTextField)] = []

  func show(
    _ screens: [CGRect], alpha: CGFloat = 0.95,
    level: NSWindow.Level = NSWindow.Level(
      rawValue: NSWindow.Level.normal.rawValue + 1),
    text: String? = nil
  ) {
    while panels.count < screens.count {
      let p = Panels.overlay(level: level)
      let t = NSTextField(labelWithString: "")
      t.font = .monospacedDigitSystemFont(ofSize: 72, weight: .light)
      t.textColor = .white
      t.translatesAutoresizingMaskIntoConstraints = false
      p.contentView?.addSubview(t)
      if let v = p.contentView {
        NSLayoutConstraint.activate([
          t.centerXAnchor.constraint(equalTo: v.centerXAnchor),
          t.centerYAnchor.constraint(equalTo: v.centerYAnchor)
        ])
      }
      panels.append((p, t))
    }
    for (n, (p, t)) in panels.enumerated() {
      guard let screen = screens[safe: n] else {
        p.orderOut(nil)
        continue
      }
      p.level = level
      t.stringValue = text ?? ""
      p.backgroundColor = NSColor.black.withAlphaComponent(alpha)
      let frame = Screens.flip(screen)
      if p.frame != frame { p.setFrame(frame, display: true) }
      if !p.isVisible { p.orderFrontRegardless() }
    }
  }
}
