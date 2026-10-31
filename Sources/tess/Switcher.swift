import AppKit
import Layout

/// cmd-tab through tess. An event tap on a thread of its own (a busy
/// main thread must never hold up typing) takes cmd-tab before the
/// Dock's switcher sees it. While cmd stays down, tab and shift-tab
/// (or the arrows) step, a letter goes to its window, esc cancels,
/// and letting go of cmd (or return) goes to the one picked. Every
/// other key passes untouched, but in Zen's break no key or click
/// gets through.
final class CmdTab {
  enum Key {
    case open(back: Bool), step(back: Bool), letter(UInt16), cancel,
      release, option(Bool), typed
  }

  /// Off while tess is paused: cmd-tab is macOS's again.
  // ponytail: a Bool written on main and read on the tap's thread; a
  // lock if it grows.
  nonisolated(unsafe) static var enabled = true

  /// Zen's break: every key and click stops here.
  nonisolated(unsafe) static var blocking = false {
    didSet {
      if blocking != oldValue, let clicks {
        CGEvent.tapEnable(tap: clicks, enable: blocking)
      }
    }
  }

  /// Clicks and scrolling, on only during a break: the rest of the
  /// time each one would stop at this thread on its way to every app.
  nonisolated(unsafe) private static var clicks: CFMachPort?

  private let onKey: (Key) -> Void
  // The tap's thread only.
  private var tap: CFMachPort?
  private var open = false
  private var optionAlone = false

  init(_ onKey: @escaping (Key) -> Void) {
    self.onKey = onKey
    let thread = Thread { [unowned self] in self.run() }
    thread.name = "tess.cmdtab"
    thread.start()
  }

  private func listen(_ events: [CGEventType]) -> CFMachPort? {
    let mask = events.reduce(CGEventMask(0)) {
      $0 | CGEventMask(1) << $1.rawValue
    }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: { _, type, e, refcon in
          Unmanaged<CmdTab>.fromOpaque(refcon!).takeUnretainedValue()
            .handle(type, e)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
    else { return nil }
    CFRunLoopAddSource(
      CFRunLoopGetCurrent(),
      CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    return tap
  }

  private func run() {
    guard let tap = listen([.keyDown, .keyUp, .flagsChanged]) else {
      Log.write("cmd-tab: no event tap, macOS keeps it")
      return
    }
    self.tap = tap
    CGEvent.tapEnable(tap: tap, enable: true)
    if let clicks = listen([
      .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
      .otherMouseDown, .otherMouseUp,
      .scrollWheel
    ]) {
      CGEvent.tapEnable(tap: clicks, enable: Self.blocking)
      Self.clicks = clicks
    }
    CFRunLoopRun()
  }

  private func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<
    CGEvent
  >? {
    let pass = Unmanaged.passUnretained(e)
    // macOS turns a tap off when it answers slowly.
    if type == .tapDisabledByTimeout
      || type == .tapDisabledByUserInput
    {
      if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      // Only ever back on: turning a tap off lands here too, so
      // turning it off from here would never end.
      if Self.blocking, let clicks = Self.clicks {
        CGEvent.tapEnable(tap: clicks, enable: true)
      }
      return pass
    }
    if Self.blocking { return nil }
    guard type == .keyDown || type == .keyUp || type == .flagsChanged
    else { return pass }
    let flags = e.flags,
      code = e.getIntegerValueField(.keyboardEventKeycode),
      back = flags.contains(.maskShift)
    if type == .flagsChanged {
      let alone =
        flags.intersection([
          .maskAlternate, .maskCommand, .maskControl, .maskShift
        ]) == .maskAlternate
      if alone != optionAlone {
        optionAlone = alone
        send(.option(alone))
      }
      if open, !flags.contains(.maskCommand) {
        open = false
        send(.release)
      }
      return pass
    }
    if optionAlone, type == .keyDown { send(.typed) }
    if !open {
      guard Self.enabled, code == 48, flags.contains(.maskCommand),
        !flags.contains(.maskAlternate),
        !flags.contains(.maskControl)
      else { return pass }
      if type == .keyDown {
        open = true
        send(.open(back: back))
      }
      return nil
    }
    // Open: every key is the switcher's until cmd comes up.
    guard type == .keyDown else { return nil }
    switch code {
    case 48: send(.step(back: back))
    case 123: send(.step(back: true))
    case 124: send(.step(back: false))
    case 53:
      open = false
      send(.cancel)
    // return, enter: the picked one, as letting go of cmd
    case 36, 76:
      open = false
      send(.release)
    default: send(.letter(UInt16(code)))
    }
    return nil
  }

  private func send(_ k: Key) {
    DispatchQueue.main.async { [onKey] in onKey(k) }
  }
}

/// The cmd-tab panel: a card per window, the picked one tinted, on
/// the screen being looked at.
final class Switcher {
  /// A window, or an app with no window on the cards (none open,
  /// hidden, minimized, on another Space): picking it brings the app
  /// forward as its Dock icon would.
  enum Target: Hashable {
    case window(WindowID)
    case app(pid_t)
  }

  struct Card {
    var target: Target
    var icon: NSImage?
    var app: String
    var title: String
    /// Screen, the app's memory and how long it has been open.
    var detail: String
    var label: Character?
  }

  private(set) var cards: [Card] = []
  private(set) var selected = 0
  private var strips: [Strip] = []
  private var panel: NSPanel?
  private let view = SwitcherView()
  /// The pick while the panel shows, nil once it closes: tess
  /// outlines a window on screen.
  var onPick: (Target?) -> Void = { _ in }

  var pick: Target? {
    cards.indices.contains(selected) ? cards[selected].target : nil
  }

  func open(
    _ cards: [Card], selected: Int, strips: [Strip] = [],
    on screen: CGRect
  ) {
    self.cards = cards
    self.selected = selected
    self.strips = strips
    // A quick cmd-tab goes without the panel flashing up.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
      [weak self] in
      guard let self, !self.cards.isEmpty else { return }
      self.show(on: screen)
    }
  }

  func step(_ by: Int) {
    guard !cards.isEmpty else { return }
    selected = (selected + by + cards.count) % cards.count
    view.selected = selected
    view.needsDisplay = true
    if panel?.isVisible == true { onPick(pick) }
  }

  /// Better titles arrived while open.
  func retitle(_ title: (Target) -> String?) {
    guard !cards.isEmpty else { return }
    for i in cards.indices {
      if let t = title(cards[i].target) { cards[i].title = t }
    }
    view.cards = cards
    view.needsDisplay = true
  }

  func close() {
    cards = []
    view.cards = []
    panel?.orderOut(nil)
    onPick(nil)
  }

  private func show(on screen: CGRect) {
    view.cards = cards
    view.selected = selected
    view.strips = strips
    let p =
      panel
      ?? {
        // Above everything, the picked window's orange outline and
        // open menus included.
        let p = Panels.overlay(level: .popUpMenu)
        p.contentView = Panels.glass(view, radius: 22)
        return p
      }()
    panel = p
    let size = SwitcherView.size(
      for: cards.count, strips: strips.count,
      within: screen.width - 80)
    let r = CGRect(
      x: screen.midX - size.width / 2,
      y: screen.midY - size.height / 2, width: size.width,
      height: size.height)
    p.setFrame(Screens.flip(r), display: true)
    view.needsDisplay = true
    p.orderFrontRegardless()
    onPick(pick)
  }
}

final class SwitcherView: NSView {
  var cards: [Switcher.Card] = []
  var selected = 0
  var strips: [Strip] = []
  static let card = NSSize(width: 168, height: 132)
  static let gap: CGFloat = 10, pad: CGFloat = 14, strip: CGFloat = 34

  override var isFlipped: Bool { true }

  static func columns(for n: Int, within width: CGFloat) -> Int {
    max(1, min(n, Int((width - 2 * pad + gap) / (card.width + gap))))
  }

  static func size(for n: Int, strips: Int = 0, within width: CGFloat)
    -> NSSize
  {
    let cols = columns(for: n, within: width),
      rows = (n + cols - 1) / cols
    return NSSize(
      width: 2 * pad + CGFloat(cols) * card.width + CGFloat(cols - 1)
        * gap,
      height: 2 * pad + CGFloat(rows) * card.height + CGFloat(
        rows - 1) * gap + CGFloat(strips) * (strip + gap))
  }

  /// A ribbon above the cards: its columns to scale, an outline
  /// around those on screen, the picked window lit, so it is clear
  /// how far along it is before going there.
  private func draw(
    _ ribbon: Strip, in r: NSRect, numbered: Bool, picked: WindowID?
  ) {
    var r = r
    if numbered {
      let number = "\(ribbon.monitor + 1)" as NSString
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: Panels.quiet
      ]
      number.draw(
        at: NSPoint(
          x: r.minX,
          y: r.midY - number.size(withAttributes: attrs).height / 2),
        withAttributes: attrs)
      r = r.insetBy(dx: 7, dy: 0).offsetBy(dx: 7, dy: 0)
    }
    let apart: CGFloat = 3
    let unit =
      (r.width - 8 - apart * CGFloat(ribbon.lanes.count - 1))
      / max(ribbon.lengths.reduce(0, +), 1)
    var x = r.minX + 4
    var inView: NSRect?
    for (lane, (length, shown)) in zip(
      ribbon.lanes, zip(ribbon.lengths, ribbon.shown))
    {
      let box = NSRect(
        x: x, y: r.minY + 4, width: unit * length,
        height: r.height - 8)
      x += box.width + apart
      if shown { inView = inView?.union(box) ?? box }
      for (i, id) in lane.enumerated() {
        let height =
          (box.height - CGFloat(lane.count - 1)) / CGFloat(lane.count)
        let cell = NSRect(
          x: box.minX, y: box.minY + CGFloat(i) * (height + 1),
          width: box.width, height: height)
        (id == picked
          ? Panels.accent : Panels.label(shown ? 0.32 : 0.14))
          .setFill()
        NSBezierPath(roundedRect: cell, xRadius: 2, yRadius: 2).fill()
      }
    }
    guard let inView else { return }
    let outline = NSBezierPath(
      roundedRect: inView.insetBy(dx: -3, dy: -3), xRadius: 4,
      yRadius: 4)
    outline.lineWidth = 1
    Panels.label(0.55).setStroke()
    outline.stroke()
  }

  override func draw(_ dirtyRect: NSRect) {
    var picked: WindowID?
    if cards.indices.contains(selected),
      case .window(let id) = cards[selected].target
    {
      picked = id
    }
    for (i, s) in strips.enumerated() {
      draw(
        s,
        in: NSRect(
          x: Self.pad,
          y: Self.pad + CGFloat(i) * (Self.strip + Self.gap),
          width: bounds.width - 2 * Self.pad, height: Self.strip),
        numbered: strips.count > 1, picked: picked)
    }
    let top =
      Self.pad + CGFloat(strips.count) * (Self.strip + Self.gap)
    let cols = Self.columns(for: cards.count, within: bounds.width)
    let center = NSMutableParagraphStyle()
    center.alignment = .center
    center.lineBreakMode = .byTruncatingTail
    for (i, c) in cards.enumerated() {
      let r = NSRect(
        x: Self.pad + CGFloat(i % cols)
          * (Self.card.width + Self.gap),
        y: top + CGFloat(i / cols) * (Self.card.height + Self.gap),
        width: Self.card.width, height: Self.card.height)
      let path = NSBezierPath(
        roundedRect: r, xRadius: 12, yRadius: 12)
      (i == selected
        ? Panels.accent.withAlphaComponent(0.28)
        : NSColor.labelColor.withAlphaComponent(0.05)).setFill()
      path.fill()
      if i == selected {
        Panels.accent.setStroke()
        path.lineWidth = 2
        path.stroke()
      }
      c.icon?.draw(
        in: NSRect(
          x: r.midX - 24, y: r.minY + 14, width: 48, height: 48))
      (c.app as NSString).draw(
        in: NSRect(
          x: r.minX + 8, y: r.minY + 68, width: r.width - 16,
          height: 17),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
          .foregroundColor: NSColor.labelColor,
          .paragraphStyle: center
        ])
      (c.title as NSString).draw(
        in: NSRect(
          x: r.minX + 8, y: r.minY + 87, width: r.width - 16,
          height: 15),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 11),
          .foregroundColor: Panels.quiet, .paragraphStyle: center
        ])
      if !c.detail.isEmpty {
        (c.detail as NSString).draw(
          in: NSRect(
            x: r.minX + 8, y: r.minY + 106, width: r.width - 16,
            height: 14),
          withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: Panels.quiet, .paragraphStyle: center
          ])
      }
      if let label = c.label {
        MapView.keycap(
          label,
          NSRect(x: r.minX + 8, y: r.minY + 8, width: 22, height: 22))
      }
    }
  }
}
