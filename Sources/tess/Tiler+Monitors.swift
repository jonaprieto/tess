import AppKit
import Layout

/// Screens coming and going, and which one is being looked at.
extension Tiler {
  func screensChanged() {
    // A lid closing drops its screen's windows from their app's list
    // for a moment: they stay in the layout, to be parked with the
    // screen and come back with it.
    spaceChangedAt = Date()
    screensWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.updateMonitors()
    }
    screensWork = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + 0.5, execute: work)
  }


  func updateMonitors() {
    let screens = Screens.current()
    let before = world.monitors.count
    world.setMonitors(
      screens.map { (id: $0.id, frame: $0.frame) },
      main: screens.first(where: \.isMain)?.id)
    // The keys for screens follow the screens there are.
    if world.monitors.count != before, !jumping, !picking {
      setMode(mode)
    }
    writes = [:]
    Log.write(
      "monitors: \(screens.map { "\($0.id.prefix(8)) \(Int($0.frame.width))x\(Int($0.frame.height))" })"
    )
    Events.record(
      "screens",
      [
        "screens": screens.enumerated().map { n, s in
          [
            "n": n + 1, "id": s.id, "frame": s.frame.json,
            "full": s.full.json, "main": s.isMain
          ] as [String: Any]
        }
      ])
    if !starting { Events.record("state", stateJSON()) }
    scheduleApply()
  }


  var activeFrame: CGRect {
    world.monitors.indices.contains(world.activeMonitor)
      ? world.monitors[world.activeMonitor].frame
      : (Screens.current().first?.frame ?? .zero)
  }


  /// Where a mode's keys show: the screen with the fewest windows
  /// (empty_screens), every screen, or (overlay.all_screens false)
  /// the one in use.
  var modeScreens: [CGRect] {
    guard !world.monitors.isEmpty else { return [lookedAtFrame] }
    if config.emptyScreens { return [leastBusyFrame] }
    return config.overlayAllScreens
      ? world.monitors.map(\.frame) : [lookedAtFrame]
  }

  /// The screen with the fewest windows, the one being looked at on a
  /// tie.
  var leastBusyFrame: CGRect {
    let looked = lookedAtFrame
    let m = world.leastBusy(
      prefer: world.monitors.firstIndex { $0.frame == looked }
        ?? world.activeMonitor)
    return world.monitors[safe: m]?.frame ?? looked
  }

  /// A new window sent to another screen says where it went.
  func announce(_ id: WindowID, on m: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      [weak self] in
      guard let self, let screen = self.world.monitors[safe: m]?.frame
      else { return }
      self.overlay.toast(
        L("\(self.appName(id)) opened on screen \(m + 1)"), on: screen
      )
      if let f = self.windowStack.first(where: { $0.id == id })?.frame
      {
        self.overlay.flash(f)
      }
    }
  }


  /// The screen being looked at: the one with macOS's focused window
  /// (also when it is a fullscreen app tess leaves alone), else the
  /// one with the mouse.
  var lookedAtFrame: CGRect {
    if let f = osFocused.flatMap({ infos[$0]?.frame }),
      let m = world.monitorIndex(for: f)
    {
      return world.monitors[m].frame
    }
    let p = mousePoint
    return world.monitors.first {
      $0.frame.insetBy(dx: 0, dy: -40).contains(p)
    }?.frame ?? activeFrame
  }

  /// The mouse in AX coordinates.
  var mousePoint: CGPoint {
    let mouse = NSEvent.mouseLocation
    return CGPoint(
      x: mouse.x,
      y: (NSScreen.screens.first?.frame.height ?? 0) - mouse.y)
  }
}
