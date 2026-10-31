import AppKit
import Layout

final class KeyPanel: NSPanel {
  override var canBecomeKey: Bool { true }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // This accessory app has no Edit menu to route the field editor's
    // shortcuts.
    if event.modifierFlags.intersection([
      .command, .option, .control, .shift
    ]) == .command,
      let editor = firstResponder as? NSTextView, editor.isEditable
    {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "v": editor.paste(nil)
      case "c": editor.copy(nil)
      case "x": editor.cut(nil)
      case "a": editor.selectAll(nil)
      default: return super.performKeyEquivalent(with: event)
      }
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

/// Step 1's rows: icon, title (matched letters in the accent color),
/// and what it is.
final class ListView: NSView {
  static let visible = 8
  static let row: CGFloat = 44
  var items: [Picker.Item] = []
  var query = ""
  var empty = L("Nothing matches")
  var selected = 0
  private var top = 0

  override var isFlipped: Bool { true }

  func move(_ by: Int) {
    guard !items.isEmpty else { return }
    selected = min(max(selected + by, 0), items.count - 1)
    if selected < top { top = selected }
    if selected >= top + Self.visible {
      top = selected - Self.visible + 1
    }
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    if selected < top || selected >= top + Self.visible {
      top = max(0, selected - Self.visible + 1)
    }
    if items.isEmpty {
      (empty as NSString).draw(
        at: NSPoint(x: 16, y: 12),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: 14),
          .foregroundColor: Panels.quiet
        ])
      return
    }
    for (n, i) in (top..<min(items.count, top + Self.visible))
      .enumerated()
    {
      let item = items[i]
      let r = NSRect(
        x: 0, y: CGFloat(n) * Self.row, width: bounds.width,
        height: Self.row)
      if i == selected {
        let bg = r.insetBy(dx: 2, dy: 2)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 8, yRadius: 8).fill()
        Panels.accent.setFill()
        NSBezierPath(
          roundedRect: NSRect(
            x: bg.minX + 4, y: bg.minY + 8, width: 3,
            height: bg.height - 16),
          xRadius: 1.5, yRadius: 1.5
        ).fill()
      }
      item.icon?.draw(
        in: NSRect(x: 12, y: r.midY - 12, width: 24, height: 24))
      let detailAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12),
        .foregroundColor: Panels.quiet
      ]
      let detail = item.detail as NSString
      let style = NSMutableParagraphStyle()
      style.lineBreakMode = .byTruncatingMiddle
      detail.draw(
        in: NSRect(
          x: 44, y: r.minY + 24, width: r.width - 58, height: 16),
        withAttributes: detailAttrs.merging([.paragraphStyle: style])
        { $1 })
      title(item.title).draw(
        in: NSRect(
          x: 44, y: r.minY + (item.detail.isEmpty ? 12 : 5),
          width: r.width - 58, height: 20))
    }
  }

  private func title(_ text: String) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    let s = NSMutableAttributedString(
      string: text,
      attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor.labelColor, .paragraphStyle: style
      ])
    let chars = Array(text)
    for p in fuzzyPositions(query, text) ?? [] {
      // Character index to UTF-16 range.
      let start = String(chars[..<p]).utf16.count
      s.addAttributes(
        [
          .foregroundColor: Panels.readable(Panels.accent),
          .font: NSFont.systemFont(ofSize: 14, weight: .bold)
        ],
        range: NSRange(
          location: start, length: String(chars[p]).utf16.count))
    }
    return s
  }
}

/// Step 2: every monitor as arranged, each tiled window with its app
/// icon and a keycap letter.
final class MapView: NSView {
  var model = Picker.Map(monitors: [], windows: [], labels: [:])
  var picked: WindowID?
  var title = ""
  var icon: NSImage?

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    icon?.draw(in: NSRect(x: 22, y: 18, width: 26, height: 26))
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingMiddle
    (L("Where should “\(title)” go?") as NSString).draw(
      in: NSRect(x: 56, y: 20, width: bounds.width - 80, height: 24),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
        .foregroundColor: NSColor.labelColor, .paragraphStyle: style
      ])
    guard
      let all = model.monitors.reduce(
        nil, { (u: CGRect?, r) in u?.union(r) ?? r }), all.width > 0
    else { return }
    let area = NSRect(
      x: 22, y: 60, width: bounds.width - 44,
      height: bounds.height - 72)
    let scale = min(area.width / all.width, area.height / all.height)
    let offset = CGPoint(
      x: area.minX + (area.width - all.width * scale) / 2,
      y: area.minY + (area.height - all.height * scale) / 2)
    func mini(_ r: CGRect) -> CGRect {
      CGRect(
        x: offset.x + (r.minX - all.minX) * scale,
        y: offset.y + (r.minY - all.minY) * scale,
        width: r.width * scale, height: r.height * scale)
    }
    let boxes = model.monitors.map { mini($0).insetBy(dx: 5, dy: 5) }
    for (n, box) in boxes.enumerated() {
      let warning = model.monitorWarnings[n]
      let path = NSBezierPath(
        roundedRect: box, xRadius: 12, yRadius: 12)
      NSColor.labelColor.withAlphaComponent(0.05).setFill()
      path.fill()
      NSColor.labelColor.withAlphaComponent(0.25).setStroke()
      path.lineWidth = 1
      path.stroke()
      // The screen's number key heads it, in the inverse of the
      // window letters.
      if let digit = "\(n + 1)".first {
        Self.keycap(
          digit,
          NSRect(
            x: box.minX + 8, y: box.minY + 7, width: 24, height: 24),
          fill: warning == nil ? .labelColor : .systemOrange)
      }
      ((warning.map { L("⚠ \($0) may not fit") }
        ?? L("Screen \(n + 1)")) as NSString).draw(
          in: NSRect(
            x: box.minX + 40, y: box.minY + 11, width: box.width - 48,
            height: 16),
          withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: Panels.quiet
          ])
    }
    // A window inside its screen's box, below the header.
    func inScreen(_ r: CGRect) -> CGRect {
      guard
        let i = model.monitors.firstIndex(where: {
          $0.contains(CGPoint(x: r.midX, y: r.midY))
        })
      else { return mini(r) }
      let m = model.monitors[i], b = boxes[i]
      let inner = CGRect(
        x: b.minX + 2, y: b.minY + 36, width: b.width - 4,
        height: b.height - 38)
      return CGRect(
        x: inner.minX + (r.minX - m.minX) / m.width * inner.width,
        y: inner.minY + (r.minY - m.minY) / m.height * inner.height,
        width: r.width / m.width * inner.width,
        height: r.height / m.height * inner.height)
    }
    for w in model.windows {
      let warnings = [
        model.replaceWarnings[w.id].map { L("swap: \($0)") },
        model.besideWarnings[w.id].map { L("beside: \($0)") }
      ].compactMap { $0 }
      let warning =
        warnings.isEmpty
        ? nil : L("⚠ \(warnings.joined(separator: "; ")) may not fit")
      let caption = warning ?? w.title
      let capColor: NSColor =
        warning == nil ? Panels.accent : .systemOrange
      let r = inScreen(w.frame).insetBy(dx: 4, dy: 4)
      guard r.width > 4, r.height > 4 else { continue }
      let isPicked = w.id == picked
      let path = NSBezierPath(
        roundedRect: r, xRadius: min(9, r.height / 3),
        yRadius: min(9, r.height / 3))
      (isPicked
        ? Panels.accent.withAlphaComponent(0.35)
        : NSColor.labelColor.withAlphaComponent(0.1)).setFill()
      path.fill()
      (isPicked
        ? Panels.readable(Panels.accent)
        : NSColor.labelColor.withAlphaComponent(0.18)).setStroke()
      path.lineWidth = isPicked ? 2 : 1
      path.stroke()
      NSGraphicsContext.saveGraphicsState()
      path.addClip()
      let clip = NSMutableParagraphStyle()
      clip.lineBreakMode = .byTruncatingTail
      let label = model.labels[w.id]
      if r.height < 72 {
        // A compact row: keycap, icon and "App · title" on one line.
        let side = min(24, r.height - 6)
        var x = r.minX + 6
        if let label {
          Self.keycap(
            label,
            NSRect(
              x: x, y: r.midY - side / 2, width: side, height: side),
            fill: capColor)
          x += side + 6
        }
        let icon = min(18, r.height - 6)
        w.icon?.draw(
          in: NSRect(
            x: x, y: r.midY - icon / 2, width: icon, height: icon))
        x += icon + 6
        let line = NSMutableAttributedString(
          string: w.app,
          attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor
          ])
        if !caption.isEmpty {
          line.append(
            NSAttributedString(
              string: "  \(caption)",
              attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: warning == nil
                  ? Panels.quiet : Panels.readable(.systemOrange)
              ]))
        }
        line.addAttribute(
          .paragraphStyle, value: clip,
          range: NSRange(location: 0, length: line.length))
        line.draw(
          in: NSRect(
            x: x, y: r.midY - 8, width: r.maxX - x - 6, height: 16))
      } else {
        let side = min(40, r.height * 0.35, r.width * 0.4)
        let iconRect = NSRect(
          x: r.midX - side / 2, y: r.midY - side / 2 - 12,
          width: side, height: side)
        w.icon?.draw(in: iconRect)
        clip.alignment = .center
        (w.app as NSString).draw(
          in: NSRect(
            x: r.minX + 8, y: iconRect.maxY + 6, width: r.width - 16,
            height: 16),
          withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: clip
          ])
        (caption as NSString).draw(
          in: NSRect(
            x: r.minX + 8, y: iconRect.maxY + 22, width: r.width - 16,
            height: 30),
          withAttributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: warning == nil
              ? Panels.quiet : Panels.readable(.systemOrange),
            .paragraphStyle: clip
          ])
        if let label {
          Self.keycap(
            label,
            NSRect(
              x: r.minX + 9, y: r.minY + 9, width: 28, height: 28),
            fill: capColor)
        }
      }
      NSGraphicsContext.restoreGraphicsState()
    }
  }

  static func keycap(
    _ label: Character, _ cap: NSRect, fill: NSColor? = nil
  ) {
    let fill = fill ?? Panels.accent
    fill.setFill()
    NSBezierPath(
      roundedRect: cap, xRadius: cap.height / 4,
      yRadius: cap.height / 4
    ).fill()
    let text = String(label).uppercased() as NSString
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(
        ofSize: cap.height * 0.55, weight: .bold),
      .foregroundColor: Panels.ink(on: fill)
    ]
    let s = text.size(withAttributes: attrs)
    text.draw(
      at: NSPoint(
        x: cap.midX - s.width / 2, y: cap.midY - s.height / 2),
      withAttributes: attrs)
  }
}
