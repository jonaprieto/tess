import AppKit
import Layout

/// Labels: a thin border and a letter on every window and a number on
/// every screen (`all`), or only the focused window's border; and an
/// outline on the active screen. One click-through panel per screen,
/// just above normal windows, redrawn after each layout pass. In jump
/// mode the letters grow, since they are then the keys.
final class Decorations {
  struct Window: Equatable {
    var frame: CGRect
    var label: Character?
    var focused: Bool
  }

  /// What is on screen, so that nothing is redrawn when it would come
  /// out the same.
  struct Drawn: Equatable {
    var screens: [CGRect]
    var windows: [Window]
    var tabs: [CGRect]
    var tabLetters: [Character]
    var jumping, all: Bool
    var active: Int?
  }

  private var panels: [NSPanel] = []

  func update(
    screens: [CGRect], windows: [Window],
    tabs: [(frame: CGRect, label: Character)], jumping: Bool,
    all: Bool,
    active: Int?
  ) {
    while panels.count < screens.count { panels.append(Self.panel()) }
    while panels.count > screens.count {
      panels.removeLast().orderOut(nil)
    }
    for (n, screen) in screens.enumerated() {
      let p = panels[n]
      let view: DecorationView
      if let v = p.contentView as? DecorationView {
        view = v
      } else {
        view = DecorationView()
        p.contentView = view
      }
      view.screen = screen
      view.number = n + 1
      view.jumping = jumping
      view.all = all
      view.active = n == active
      view.windows = windows.filter { screen.intersects($0.frame) }
      view.tabs = tabs.filter { screen.intersects($0.frame) }
      let frame = Screens.flip(screen)
      if p.frame != frame { p.setFrame(frame, display: false) }
      view.needsDisplay = true
      if !p.isVisible { p.orderFrontRegardless() }
    }
  }

  /// Hidden, but kept for the next time (jump mode shows them again).
  func hide() {
    panels.forEach { $0.orderOut(nil) }
  }

  private static func panel() -> NSPanel {
    Panels.overlay(level: .floating, missionControl: .transient)
  }
}

final class DecorationView: NSView {
  var screen = CGRect.zero
  var number = 1
  var jumping = false
  var all = false
  var active = false
  var windows: [Decorations.Window] = []
  var tabs: [(frame: CGRect, label: Character)] = []

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    func local(_ r: CGRect) -> CGRect {
      r.offsetBy(dx: -screen.minX, dy: -screen.minY)
    }
    if active {
      let path = NSBezierPath(
        roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10,
        yRadius: 10)
      path.lineWidth = 1
      Panels.readable(Panels.accent).withAlphaComponent(0.3)
        .setStroke()
      path.stroke()
    }
    // Borders first, the focused one last so it is on top.
    for w in windows.sorted(by: { !$0.focused && $1.focused }) {
      let r = local(w.frame).insetBy(dx: -1, dy: -1)
      let path = NSBezierPath(
        roundedRect: r, xRadius: 12, yRadius: 12)
      path.lineWidth = w.focused ? 1.5 : 1
      (w.focused
        ? Panels.readable(Panels.accent).withAlphaComponent(0.75)
        : Panels.inactiveBorder).setStroke()
      path.stroke()
    }
    // Letters on each window: in its middle while they are keys
    // (clear of a tab bar), else on its top border; windows sharing a
    // frame (an accordion) get theirs side by side.
    var shared: [String: Int] = [:]
    let height: CGFloat = jumping ? 40 : 20
    for w in windows {
      guard let label = w.label else { continue }
      // What the screen shows of it: a window parked on a ribbon's
      // strip is mostly past it.
      let r = local(w.frame).intersection(bounds)
      let key = "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))"
      let i = shared[key, default: 0]
      shared[key] = i + 1
      let width = height + 6
      let x = r.midX - width / 2 + CGFloat(i) * (width + 4)
      badge(
        String(label).uppercased(),
        NSRect(
          x: x, y: (jumping ? r.midY : r.minY) - height / 2,
          width: width, height: height),
        strong: w.focused || jumping)
    }
    // Tab letters on the tabs.
    for t in tabs {
      let r = local(t.frame)
      badge(
        String(t.label).uppercased(),
        NSRect(x: r.midX - 13, y: r.midY - 12, width: 26, height: 24),
        strong: true)
    }
    // The screen's number in its bottom-left corner (top-left would
    // sit on a window's close button).
    guard all else { return }
    let side: CGFloat = jumping ? 34 : 22
    badge(
      "\(number)",
      NSRect(
        x: 2, y: bounds.height - side - 2, width: side, height: side),
      strong: jumping, round: true)
  }

  private func badge(
    _ text: String, _ r: NSRect, strong: Bool, round: Bool = false
  ) {
    let path = NSBezierPath(
      roundedRect: r, xRadius: round ? r.height / 2 : 6,
      yRadius: round ? r.height / 2 : 6)
    (strong
      ? Panels.accent
      : NSColor.windowBackgroundColor.withAlphaComponent(0.92))
      .setFill()
    path.fill()
    NSColor.labelColor.withAlphaComponent(strong ? 0 : 0.25)
      .setStroke()
    path.lineWidth = 0.5
    path.stroke()
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(
        ofSize: r.height * 0.58, weight: .bold),
      .foregroundColor: strong
        ? Panels.ink(on: Panels.accent) : NSColor.labelColor
    ]
    let s = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(
      at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2),
      withAttributes: attrs)
  }
}
