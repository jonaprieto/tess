import AppKit
import Layout

/// Window letters, tab letters, screen numbers and jump mode.
extension Tiler {
  // MARK: Labels and jump mode

  /// Visible windows in screen, lane and stack order, then floating
  /// ones.
  var labeledWindows: [WindowID] {
    (world.tiled + world.floating.sorted()).filter {
      infos[$0] != nil && !offSpace.contains($0)
    }
  }

  /// Letters are keys: in jump mode, and in tess mode on the letters
  /// it leaves free.
  var labelsAreKeys: Bool { jumping || mode == "tess" }

  /// The letters windows and tabs wear: those tess mode does not use,
  /// so they are keys there too.
  var labelPool: String {
    labelLetters(free: config.modes["tess"] ?? [:])
  }

  /// The visible windows, without those under another's tess
  /// fullscreen.
  var shownWindows: [WindowID] {
    labeledWindows.filter { id in
      guard let p = world.locate(id),
        let fs = world.monitors[p.m].fullscreen
      else { return true }
      return fs == id
    }
  }


  /// The windows on screen front to back, by the window server (app
  /// windows only, not tess's panels).
  var windowStack: [(id: WindowID, frame: CGRect)] {
    let list =
      CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w in
      guard (w[kCGWindowLayer as String] as? Int) == 0,
        let id = (w[kCGWindowNumber as String] as? NSNumber)?
          .uint32Value,
        let b = w[kCGWindowBounds as String] as? NSDictionary,
        let r = CGRect(dictionaryRepresentation: b)
      else { return nil }
      return (id, r)
    }
  }

  /// The shown windows whose middle is not under another window, and
  /// those parked on a ribbon's strip, which keep a letter whichever
  /// of them macOS has in front.
  func visibleWindows(_ stack: [(id: WindowID, frame: CGRect)])
    -> [WindowID]
  {
    let parked = world.parked(
      inner: config.inner, outer: config.outer)
    return shownWindows.filter { id in
      stack.first(where: { $0.id == id }).map {
        parked.contains(id)
          || onTop(
            CGPoint(x: $0.frame.midX, y: $0.frame.midY), id, stack)
      } ?? false
    }
  }

  /// A window on its way has no outline: its app has not reported the
  /// frame tess wrote, or the window server has not got to what the
  /// app reported.
  func inTransit(_ id: WindowID, at frame: CGRect) -> Bool {
    assumed.contains(id)
      || (landing[id].map { Date() < $0 } == true
        && infos[id]?.frame.isNear(frame) == false)
  }

  /// Outlines use the window server's bounds, never an optimistic
  /// resize or a clipped tile.
  func decorationWindows(
    in stack: [(id: WindowID, frame: CGRect)], focused: WindowID?,
    all: Bool
  ) -> [Decorations.Window] {
    (all ? visibleWindows(stack) : shownWindows).compactMap { id in
      guard all || id == focused,
        let frame = stack.first(where: { $0.id == id })?.frame,
        !inTransit(id, at: frame)
      else { return nil }
      return Decorations.Window(
        frame: frame, label: all ? labels[id] : nil,
        focused: id == focused)
    }
  }

  /// Borders and grayscale share one fresh window-server snapshot,
  /// without caching across events.
  func refreshOverlays() {
    let stack = windowStack
    refreshDecorations(in: stack)
    refreshGray(in: stack)
    // Until what was written has landed, nothing says it did.
    landing = landing.filter { id, until in
      Date() < until
        && stack.first { $0.id == id }.map {
          inTransit(id, at: $0.frame)
        } ?? false
    }
    guard !landing.isEmpty, !landingCheck else { return }
    landingCheck = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
      [weak self] in
      self?.landingCheck = false
      self?.refreshOverlays()
    }
  }

  /// Borders and letters on every visible window, tab letters and
  /// numbers on every screen when letters are keys or labels are
  /// always on; otherwise the focused window's border and, with more
  /// than one screen, the active screen's outline
  /// (overlay.window_labels). Only what can be seen gets a letter.
  /// None during a drag, whose windows they would not follow.
  func refreshDecorations(
    in snapshot: [(id: WindowID, frame: CGRect)]? = nil
  ) {
    let stack = snapshot ?? windowStack
    let visible = visibleWindows(stack)
    labels = stableLabels(
      labels, windows: visible, alphabet: labelPool)
    let all = config.windowLabels == .always || labelsAreKeys
    guard config.windowLabels != .off, !paused, !starting,
      drag == nil, !gliding
    else {
      if drawn != nil { decorations.hide() }
      drawn = nil
      return
    }
    // Focus is only marked while its app is in front: with tess's own
    // Settings or a window tess does not track in front, a border on
    // the window behind it would cross that one.
    let front = NSWorkspace.shared.frontmostApplication?
      .processIdentifier
    let focused = world.focused.flatMap { id in
      infos[id]?.pid == front ? id : nil
    }
    let windows = decorationWindows(
      in: stack, focused: focused, all: all)
    let tabs = zip(tabList, tabLetters).map {
      (frame: $0.frame, label: $1)
    }
    let screens = world.monitors.map(\.frame)
    let active = screens.count > 1 ? world.activeMonitor : nil
    let now = Decorations.Drawn(
      screens: screens, windows: windows, tabs: tabs.map(\.frame),
      tabLetters: tabs.map(\.label),
      jumping: labelsAreKeys, all: all, active: active)
    guard now != drawn else { return }
    drawn = now
    decorations.update(
      screens: screens, windows: windows, tabs: tabs,
      jumping: labelsAreKeys, all: all, active: active)
  }


  /// While letters are keys, the tabs of the windows on screen (the
  /// focused window's first) take the letters the windows left; their
  /// keys and labels follow once every app answered.
  func refreshTabs() {
    tabsAsked += 1
    let asked = tabsAsked
    tabList = []
    tabLetters = []
    guard labelsAreKeys else { return }
    let shown = visibleWindows(windowStack), f = world.focused
    let order = shown.filter { $0 == f } + shown.filter { $0 != f }
    let byApp = Dictionary(
      grouping: order.filter {
        infos[$0].flatMap { workers[$0.pid] } != nil
      }
    ) { infos[$0]!.pid }
    var found: [WindowID: [TabTarget]] = [:]
    var left = byApp.count
    for (pid, ids) in byApp {
      workers[pid]?.tabs(of: ids) { [weak self] tabs in
        guard let self, asked == self.tabsAsked else { return }
        for t in tabs {
          found[t.window, default: []].append(
            TabTarget(
              pid: pid, window: t.window, frame: t.frame,
              element: t.element))
        }
        left -= 1
        guard left == 0 else { return }
        // Tabs of a window partly covered: only those in sight.
        let stack = self.windowStack
        for (id, ts) in found {
          found[id] = ts.filter {
            onTop(
              CGPoint(x: $0.frame.midX, y: $0.frame.midY), id, stack)
          }
        }
        let free = self.labelPool.filter {
          !self.labels.values.contains($0)
        }
        self.tabList = Array(
          order.flatMap { found[$0] ?? [] }.prefix(free.count))
        self.tabLetters = Array(free.prefix(self.tabList.count))
        if self.jumping {
          self.registerJump()
        } else {
          self.registerMode()
        }
        self.refreshDecorations()
      }
    }
  }


  /// Option down on its own for 3 s, as if unsure where to go, shows
  /// the letters. Letting go of it leaves them, so a finger resting
  /// on the key costs nothing.
  func holdOption(_ down: Bool) {
    optionHold?.cancel()
    optionHold = nil
    if down {
      let hold = DispatchWorkItem { [weak self] in
        self?.startHeldJump()
      }
      optionHold = hold
      DispatchQueue.main.asyncAfter(
        deadline: .now() + 3, execute: hold)
    } else if jumpHeld {
      jumpHeld = false
      if jumping { setMode(jumpReturn) }
    }
  }

  func startHeldJump() {
    guard mode == "main", !paused, !picking, !starting,
      clickTargets.isEmpty, switcher.cards.isEmpty,
      NSEvent.pressedMouseButtons == 0
    else { return }
    jumpHeld = true
    startJump()
  }

  /// Every window's letter becomes a key (shift swaps with it), every
  /// tab's letter and every screen's number too (shift moves there);
  /// one use, or esc, goes back to the mode jump started from (main
  /// from a one-shot mode).
  func startJump() {
    guard !jumping else { return }
    jumpReturn = returnMode
    mode = "jump"
    Events.record("mode", ["mode": "jump"])
    refreshDecorations()
    let exits = registerJump()
    refreshTabs()
    // A cheat sheet like any mode's, for as long as jump mode lasts.
    let n = world.monitors.count
    let screens =
      n > 1
      ? [
        ("1–\(n)", L("Go to that screen")),
        ("⇧ 1–\(n)", L("Move the focused window there"))
      ] : []
    let rows =
      [
        (L("Letter"), L("Go to that window or tab")),
        (L("⇧ Letter"), L("Swap that window with the focused one"))
      ] + screens
    // Held, shift is out and letting go is the way back.
    overlay.showSheet(
      L("Jump"),
      rows: jumpHeld
        ? rows.enumerated().filter { $0.offset % 2 == 0 }.map(
          \.element) : rows,
      back: jumpHeld ? ["⌥"] : exits.map(\.symbol), on: modeScreens)
    onChange()
  }

  /// Jump mode's keys for the letters and tabs there are now; the
  /// keys that leave it.
  @discardableResult
  func registerJump() -> [KeySpec] {
    let (keys, exits) = jumpKeys(
      labels: labels, windows: labeledWindows, tabs: tabLetters,
      screens: world.monitors.count,
      back: [.mode(jumpReturn)])
    let failed = hotkeys.register(jumpHeld ? heldKeys(keys) : keys)
    if !failed.isEmpty {
      Log.write("jump: could not register \(failed)")
    }
    return exits
  }

  /// In tess mode, its bindings plus a key for every window and tab
  /// letter (shift+letter swaps).
  var tessLetterKeys: [KeySpec: [Command]] {
    jumpKeys(
      labels: labels, windows: labeledWindows, tabs: tabLetters,
      screens: 0, back: []
    ).keys
      .filter { $0.key.key.count == 1 && $0.key.key.first!.isLetter }
  }
}

/// A tab tess labeled: its app, window, where it is, and the element
/// to press.
struct TabTarget {
  var pid: pid_t
  var window: WindowID
  var frame: CGRect
  var element: AXUIElement
}
