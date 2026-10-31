import AppKit
import Layout

/// Menu bar item: a live miniature of the monitors as they are
/// arranged, with their columns and windows. The focused window and
/// the active monitor take the mode's color.
final class StatusItem: NSObject, NSMenuDelegate {
  private let item = NSStatusBar.system.statusItem(
    withLength: NSStatusItem.variableLength)
  private let tiler: Tiler
  var waitingForAccess = false

  init(_ tiler: Tiler) {
    self.tiler = tiler
    super.init()
    let menu = NSMenu()
    menu.delegate = self
    fill(menu)
    item.menu = menu
    refreshIcon()
  }

  /// Rebuilt each time it opens and not before: about 4 ms, which a
  /// mode change should not wait for.
  func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

  /// Cheap enough to run on every layout or focus change.
  private var drawn:
    (
      world: World, mode: String, paused: Bool, waiting: Bool,
      zen: String?, awake: Bool, language: Language
    )?

  /// Yellow: the menu bar's orange, green and purple dots are macOS's
  /// own, for the microphone, the camera and the screen. Edged to
  /// show on a light menu bar too.
  private static let awakeDot: NSImage = {
    let image = NSImage(
      size: NSSize(width: 9, height: 9), flipped: false
    ) { r in
      let dot = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
      NSColor.systemYellow.setFill()
      dot.fill()
      NSColor.black.withAlphaComponent(0.4).setStroke()
      dot.lineWidth = 0.5
      dot.stroke()
      return true
    }
    image.accessibilityDescription = L("keeping the Mac awake")
    return image
  }()

  /// Skipped when nothing the icon shows changed (most snapshots
  /// change nothing visible).
  func refreshIcon() {
    guard let button = item.button else { return }
    let now = (
      tiler.world, tiler.mode, tiler.paused, waitingForAccess,
      tiler.zenTitle, tiler.caffeine != nil, Strings.language
    )
    if let d = drawn, d.world == now.0, d.mode == now.1,
      d.paused == now.2, d.waiting == now.3, d.zen == now.4,
      d.awake == now.5, d.language == now.6
    {
      return
    }
    drawn = now
    button.image = minimap()
    button.imagePosition = .imageLeft
    // The mode by name next to the miniature; in main, Zen's
    // countdown if it is on.
    let word =
      waitingForAccess
      ? ""
      : tiler.paused
        ? L("paused")
        : tiler.mode == "main"
          ? now.4 ?? "" : Command.modeName(tiler.mode)
    let title = NSMutableAttributedString(
      string: word.isEmpty ? "" : " " + word.uppercased(),
      attributes: [
        .font: NSFont.monospacedDigitSystemFont(
          ofSize: 12, weight: .bold), .foregroundColor: color
      ])
    // A dot while caffeine keeps the Mac awake, so it is not left on
    // by accident.
    if now.5 {
      let dot = NSTextAttachment()
      dot.image = Self.awakeDot
      dot.bounds = CGRect(x: 0, y: 0, width: 9, height: 9)
      title.insert(NSAttributedString(attachment: dot), at: 0)
      title.insert(NSAttributedString(string: " "), at: 0)
    }
    button.attributedTitle = title
    button.toolTip =
      "tess: \(tiler.paused ? L("paused") : Command.modeName(tiler.mode))"
      + (now.5 ? L(", keeping the Mac awake") : "")
  }

  private var color: NSColor { Panels.readable(modeColor) }

  private var modeColor: NSColor {
    if waitingForAccess { return .systemRed }
    if tiler.paused { return .systemGray }
    switch tiler.mode {
    case "main":
      return tiler.zen == nil
        ? .controlAccentColor
        : tiler.zenWorking ? .systemIndigo : .systemMint
    case "resize": return .systemOrange
    case "tess": return .systemGreen
    case "jump": return .systemTeal
    default: return .systemTeal
    }
  }

  func minimap() -> NSImage {
    let world = tiler.world
    let color = color
    let monitors = world.monitors
    let paused = tiler.paused
    guard
      let bounds = monitors.map(\.frame).reduce(
        nil, { $0?.union($1) ?? $1 }), bounds.width > 0
    else {
      return NSImage(
        systemSymbolName: "square.grid.2x2",
        accessibilityDescription: "tess")!
    }
    let scale = min(16 / bounds.height, 64 / bounds.width)
    let frames = world.frames(inner: 0, outer: 0)
    func mini(_ r: CGRect) -> CGRect {
      CGRect(
        x: 1 + (r.minX - bounds.minX) * scale,
        y: 1 + (r.minY - bounds.minY) * scale,
        width: r.width * scale, height: r.height * scale)
    }
    let size = NSSize(
      width: bounds.width * scale + 2,
      height: bounds.height * scale + 2)
    let image = NSImage(size: size, flipped: true) { _ in
      let dim = NSColor.labelColor.withAlphaComponent(
        paused ? 0.25 : 0.4)
      for (m, mon) in monitors.enumerated() {
        let box = mini(mon.frame).insetBy(dx: 1, dy: 0.5)
        let outline = NSBezierPath(
          roundedRect: box, xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1
        (m == world.activeMonitor ? color : dim).setStroke()
        outline.stroke()
        // Unfocused first, so in an accordion the focused window is
        // drawn on top.
        for id in mon.windows.filter({ $0 != world.focused })
          + mon.windows.filter({ $0 == world.focused })
        {
          guard let f = frames[id] else { continue }
          let r = mini(f).intersection(box).insetBy(
            dx: 1.25, dy: 1.25)
          guard r.width > 0.5, r.height > 0.5 else { continue }
          (id == world.focused ? color : dim).setFill()
          NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
        }
      }
      return true
    }
    image.isTemplate = false
    image.accessibilityDescription = "tess"
    return image
  }

  private func fill(_ menu: NSMenu) {
    menu.removeAllItems()
    // Header: the minimap and what tess is doing.
    let header = NSMenuItem(
      title: "tess", action: nil, keyEquivalent: "")
    header.image = minimap()
    header.subtitle = tiler.summary
    header.isEnabled = false
    menu.addItem(header)
    if waitingForAccess {
      menu.addItem(
        item(
          L("Grant Accessibility Access…"), "hand.raised",
          #selector(openAccessibility)))
    }
    if let error = tiler.configError {
      let e = NSMenuItem(
        title: L("Config error"), action: #selector(openSettings),
        keyEquivalent: "")
      e.target = self
      e.subtitle = error
      e.image = NSImage(
        systemSymbolName: "exclamationmark.triangle",
        accessibilityDescription: nil)
      menu.addItem(e)
    }
    arrangements(menu)
    recent(menu)
    menu.addItem(.separator())
    menu.addItem(
      item(
        L("Open Picker…"), "magnifyingglass", #selector(pick),
        for: .pick("")))
    let zen = item(
      tiler.zen == nil ? "Zen" : L("Leave Zen"), "moon",
      #selector(toggleZen), for: .zen)
    let breaks = tiler.breaksToday
    zen.subtitle =
      (tiler.zenTitle ?? L("25 min focus, 5 min break"))
      + (breaks == 0
        ? ""
        : " · "
          + (breaks == 1
            ? L("1 break today") : L("\(breaks) breaks today")))
    menu.addItem(zen)
    let cup = item(
      tiler.caffeine == nil
        ? L("Keep Awake") : L("Let the Mac Sleep"), "cup.and.saucer",
      #selector(toggleCaffeine),
      for: .caffeine(nil))
    cup.subtitle =
      tiler.caffeine.map { c in
        c.until.map {
          L(
            "awake until \($0.formatted(date: .omitted, time: .shortened))"
          )
        } ?? L("awake until turned off")
      } ?? L("keep the Mac awake")
    menu.addItem(cup)
    menu.addItem(
      item(
        L("Settings…"), "gearshape", #selector(openSettings),
        key: ",", mods: [.command]))
    menu.addItem(
      item(
        L("Tutorial…"), "questionmark.circle", #selector(openTutorial)
      ))
    menu.addItem(
      item(L("Doctor…"), "stethoscope", #selector(openDoctor)))
    menu.addItem(.separator())
    menu.addItem(
      item(
        L("Rescue Windows"), "lifepreserver", #selector(rescue),
        for: .rescue))
    menu.addItem(
      item(
        L("Re-tile"), "rectangle.3.group", #selector(retile),
        for: .retile))
    menu.addItem(
      item(
        L("Clear This Screen"), "rectangle.portrait.and.arrow.right",
        #selector(clear), for: .clearMonitor))
    menu.addItem(
      tiler.paused
        ? item(L("Resume Tiling"), "play.circle", #selector(pause))
        : item(
          L("Pause Tiling"), "pause.circle", #selector(pause),
          for: .pause))
    menu.addItem(.separator())
    menu.addItem(
      item(
        L("Reload Config"), "arrow.clockwise", #selector(reload),
        for: .reload))
    menu.addItem(item(L("Open Log"), "doc.text", #selector(openLog)))
    menu.addItem(.separator())
    menu.addItem(
      item(
        L("Quit tess"), "power", #selector(quit), key: "q",
        mods: [.command]))
  }

  /// The commands behind the layout pictures, by button tag.
  private var choices: [Command] = []

  /// A row of pictures of the active screen, one per arrangement and
  /// fullscreen, each drawn from the layout it would give; clicking
  /// one does it. One that would change nothing, or that looks like
  /// one before it, is left out.
  private func arrangements(_ menu: NSMenu) {
    let world = tiler.world
    let m = world.activeMonitor
    guard !tiler.paused, world.monitors.indices.contains(m) else {
      return
    }
    let row = NSStackView()
    row.spacing = 6
    row.edgeInsets = NSEdgeInsets(
      top: 2, left: 12, bottom: 4, right: 12)
    // By the frames they give, not the model: lanes weighted 1 and 1
    // or 0.5 and 0.5 look alike.
    var shown = [world.frames(inner: 0, outer: 0)]
    choices = []
    for c in Arrangement.allCases.map(Command.arrange) + [.fullscreen]
    {
      var after = world
      if case .arrange(let a) = c {
        after.arrange(a)
      } else {
        guard let f = world.focused, world.locate(f)?.m == m,
          world.monitors[m].fullscreen != f
        else { continue }
        after.toggleFullscreen()
      }
      let frames = after.frames(inner: 0, outer: 0)
      guard !shown.contains(frames) else { continue }
      shown.append(frames)
      let b = NSButton(
        image: picture(after, m), target: self,
        action: #selector(choose(_:)))
      b.bezelStyle = .accessoryBarAction
      b.showsBorderOnlyWhileMouseInside = true
      b.tag = choices.count
      let key = tiler.config.modes["main"]?.first { $0.value == [c] }?
        .key.symbol
      b.toolTip = [c.label, key].compactMap { $0 }.joined(
        separator: "  ")
      row.addArrangedSubview(b)
      choices.append(c)
    }
    guard !choices.isEmpty else { return }
    menu.addItem(.separator())
    menu.addItem(.sectionHeader(title: L("Layout")))
    row.frame.size = row.fittingSize
    let item = NSMenuItem()
    item.view = row
    menu.addItem(item)
  }

  /// Monitor `m` of `world` small: its outline and its windows, the
  /// focused one in color.
  private func picture(_ world: World, _ m: Int) -> NSImage {
    let mon = world.monitors[m]
    let scale = min(44 / mon.frame.width, 28 / mon.frame.height)
    let size = NSSize(
      width: mon.frame.width * scale, height: mon.frame.height * scale
    )
    let frames = world.frames(inner: 0, outer: 0)
    let color = color
    return NSImage(size: size, flipped: true) { _ in
      let dim = NSColor.labelColor.withAlphaComponent(0.4)
      dim.setStroke()
      NSBezierPath(
        roundedRect: CGRect(origin: .zero, size: size).insetBy(
          dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3
      ).stroke()
      // The focused one last, so a fullscreen window is drawn over
      // the others.
      for id in mon.windows.filter({ $0 != world.focused })
        + mon.windows.filter({ $0 == world.focused })
      {
        guard let f = frames[id] else { continue }
        let r = CGRect(
          x: (f.minX - mon.frame.minX) * scale,
          y: (f.minY - mon.frame.minY) * scale,
          width: f.width * scale, height: f.height * scale
        ).insetBy(dx: 2, dy: 2)
        (id == world.focused ? color : dim).setFill()
        NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5)
          .fill()
      }
      return true
    }
  }

  /// The last changes, newest first, in a submenu. Clicking one in
  /// effect undoes it and what came after; clicking an undone one
  /// (dimmed) redoes up to it.
  private func recent(_ menu: NSMenu) {
    guard !tiler.history.isEmpty else { return }
    let rows = NSMenu()
    rows.addItem(.sectionHeader(title: L("Click to undo or redo")))
    let applied = tiler.history.count - tiler.undone
    let ago = RelativeDateTimeFormatter()
    ago.unitsStyle = .short
    ago.dateTimeStyle = .named
    ago.locale = Locale(identifier: Strings.language.rawValue)
    for (i, step) in tiler.history.enumerated().reversed() {
      let done = i < applied
      let row = NSMenuItem(
        title: step.title, action: #selector(revisit(_:)),
        keyEquivalent: "")
      row.target = self
      row.tag = i
      row.subtitle = [
        ago.localizedString(for: step.at, relativeTo: Date()),
        step.detail
      ].filter { !$0.isEmpty }
        .joined(separator: " · ")
      row.image = NSImage(
        systemSymbolName: done
          ? "arrow.uturn.backward" : "arrow.uturn.forward",
        accessibilityDescription: nil)
      row.toolTip =
        done
        ? L("Undo this and everything after it")
        : L("Redo up to here")
      if !done {
        row.attributedTitle = NSAttributedString(
          string: step.title,
          attributes: [.foregroundColor: NSColor.secondaryLabelColor])
      }
      rows.addItem(row)
    }
    menu.addItem(.separator())
    let history = NSMenuItem(
      title: L("History"), action: nil, keyEquivalent: "")
    history.image = NSImage(
      systemSymbolName: "clock.arrow.circlepath",
      accessibilityDescription: nil)
    history.submenu = rows
    menu.addItem(history)
  }

  /// A menu row with a symbol, showing the main-mode shortcut bound
  /// to `command` if any.
  private func item(
    _ title: String, _ symbol: String, _ selector: Selector,
    for command: Command? = nil,
    key: String = "", mods: NSEvent.ModifierFlags = []
  ) -> NSMenuItem {
    let i = NSMenuItem(
      title: title, action: selector, keyEquivalent: key)
    i.target = self
    i.image = NSImage(
      systemSymbolName: symbol, accessibilityDescription: nil)
    i.keyEquivalentModifierMask = mods
    if let command,
      let spec = tiler.config.modes["main"]?.first(where: {
        $0.value == [command]
      })?.key,
      let k = Self.equivalents[spec.key]
        ?? (spec.key.count == 1 ? spec.key : nil)
    {
      i.keyEquivalent = k
      var m: NSEvent.ModifierFlags = []
      if spec.mods.contains(.cmd) { m.insert(.command) }
      if spec.mods.contains(.alt) { m.insert(.option) }
      if spec.mods.contains(.ctrl) { m.insert(.control) }
      if spec.mods.contains(.shift) { m.insert(.shift) }
      i.keyEquivalentModifierMask = m
    }
    return i
  }

  private static let equivalents: [String: String] = [
    "space": " ", "backspace": "\u{8}", "tab": "\t", "enter": "\r",
    "esc": "\u{1b}", "semicolon": ";",
    "slash": "/", "minus": "-", "equal": "=", "comma": ",",
    "period": ".", "quote": "'", "backtick": "`"
  ]

  @objc private func revisit(_ sender: NSMenuItem) {
    tiler.revisit(sender.tag)
  }
  @objc private func choose(_ sender: NSButton) {
    sender.enclosingMenuItem?.menu?.cancelTracking()
    _ = tiler.run([choices[sender.tag]], source: "menu")
  }
  @objc private func pick() {
    _ = tiler.run([.pick("")], source: "menu")
  }
  @objc private func toggleZen() {
    _ = tiler.run([.zen], source: "menu")
  }
  @objc private func toggleCaffeine() {
    _ = tiler.run([.caffeine(nil)], source: "menu")
  }
  @objc private func clear() {
    _ = tiler.run([.clearMonitor], source: "menu")
  }
  @objc private func openLog() { NSWorkspace.shared.open(Log.url) }
  @objc private func openSettings() { tiler.openSettings() }
  @objc private func openTutorial() {
    _ = tiler.run([.tutorial], source: "menu")
  }
  @objc private func openDoctor() { tiler.doctor.show() }
  @objc private func rescue() { tiler.menuRescue() }
  @objc private func retile() { tiler.menuRetile() }
  @objc private func pause() { tiler.menuPause() }
  @objc private func reload() { tiler.menuReload() }
  @objc private func quit() { NSApp.terminate(nil) }

  @objc private func openAccessibility() {
    NSWorkspace.shared.open(
      URL(
        string:
          "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
      )!)
  }

}
