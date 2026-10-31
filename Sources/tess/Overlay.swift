import AppKit
import Layout

/// On-screen feedback: the keys of the current mode, a border flash
/// on the focused window, and short toasts. Click-through panels
/// above all windows that never take focus. Rects are in AX
/// coordinates (top-left origin), like everything else in tess.
@MainActor
final class Overlay {
  private var modePanels: [NSPanel] = []
  private var toastPanel: NSPanel?
  private var flashPanel: NSPanel?
  private var dropPanel: NSPanel?
  private var dropCaption: NSView?
  private var swapPanel: NSPanel?
  private var hintPanel: NSPanel?
  private var toastHide: DispatchWorkItem?
  private var flashHide: DispatchWorkItem?
  struct Download {
    let id: UUID
    let title: String
    var status: String?
  }
  private(set) var downloads: [Download] = []
  private(set) var downloadPanel: NSPanel?
  private var downloadScreen = CGRect.zero

  func beginDownload(_ title: String, on screen: CGRect) -> UUID {
    if downloads.isEmpty { downloadScreen = screen }
    let id = UUID()
    downloads.append(Download(id: id, title: title))
    refreshDownloads()
    return id
  }

  func finishDownload(_ id: UUID, status: String) {
    guard let i = downloads.firstIndex(where: { $0.id == id }) else {
      return
    }
    downloads[i].status = status
    refreshDownloads()
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
      [weak self] in
      self?.downloads.removeAll { $0.id == id }
      self?.refreshDownloads()
    }
  }

  private func refreshDownloads() {
    (downloadPanel?.contentView as? NSGlassEffectView)?.contentView?
      .subviews
      .compactMap { $0 as? NSProgressIndicator }.forEach {
        $0.stopAnimation(nil)
      }
    guard !downloads.isEmpty else {
      downloadPanel?.orderOut(nil)
      downloadPanel = nil
      return
    }
    let width = min(440, downloadScreen.width - 48)
    let height = CGFloat(downloads.count) * 82 + 16
    let content = NSView(
      frame: NSRect(x: 0, y: 0, width: width, height: height))
    for (i, download) in downloads.enumerated() {
      let y = height - CGFloat(i + 1) * 82
      let label = NSTextField(
        labelWithString:
          "\(download.status ?? L("Downloading…"))\n\(download.title)"
      )
      label.font = .systemFont(ofSize: 14, weight: .medium)
      label.maximumNumberOfLines = 2
      label.lineBreakMode = .byTruncatingMiddle
      label.frame = NSRect(
        x: 18, y: y + 26, width: width - 36, height: 40)
      content.addSubview(label)
      if download.status == nil {
        let progress = NSProgressIndicator(
          frame: NSRect(
            x: 18, y: y + 10, width: width - 36, height: 12))
        progress.style = .bar
        progress.isIndeterminate = true
        progress.setAccessibilityLabel(
          L("Downloading \(download.title)"))
        content.addSubview(progress)
        progress.startAnimation(nil)
      }
    }
    let panel = downloadPanel ?? Self.panel()
    downloadPanel = panel
    panel.contentView = Panels.glass(content, radius: 14)
    panel.setFrame(
      Screens.flip(
        CGRect(
          x: downloadScreen.maxX - width - 24,
          y: downloadScreen.maxY - height - 24, width: width,
          height: height)), display: true)
    panel.orderFrontRegardless()
  }

  /// The keys of a mode as a glass cheat sheet in the bottom-right
  /// corner of each of `screens`: grouped columns of keycaps and
  /// plain labels, so the windows being arranged stay visible.
  /// `letters`: window and tab letters are keys too, which gets a row
  /// of its own.
  func showMode(
    _ name: String, _ bindings: [KeySpec: [Command]],
    on screens: [CGRect], letters: Bool = false
  ) {
    show(on: screens) {
      ModeSheet(name: name, bindings: bindings, letters: letters)
    }
  }

  /// A sheet with given rows, for jump mode, whose keys are the
  /// window letters.
  func showSheet(
    _ title: String, rows: [(String, String)], back: [String],
    on screens: [CGRect]
  ) {
    show(on: screens) {
      ModeSheet(title: title, rows: rows, back: back)
    }
  }

  private func show(on screens: [CGRect], _ make: () -> ModeSheet) {
    hideMode()
    for screen in screens {
      let view = make()
      let size = view.fittingSize
      let r = CGRect(
        x: screen.maxX - size.width - 24,
        y: screen.maxY - size.height - 24, width: size.width,
        height: size.height)
      let p = Self.panel()
      let glass = NSGlassEffectView()
      glass.cornerRadius = 18
      glass.contentView = view
      p.contentView = glass
      p.setFrame(Screens.flip(r), display: true)
      p.orderFrontRegardless()
      modePanels.append(p)
    }
  }

  func hideMode() {
    modePanels.forEach { $0.orderOut(nil) }
    modePanels = []
  }

  func toast(
    _ message: String, on screen: CGRect, seconds: Double = 1.5
  ) {
    toastHide?.cancel()
    toastPanel?.orderOut(nil)
    toastPanel = bubble(
      NSAttributedString(
        string: message,
        attributes: [
          .font: NSFont.systemFont(ofSize: 14, weight: .medium),
          .foregroundColor: NSColor.labelColor
        ]), on: screen, at: .bottom)
    let hide = DispatchWorkItem { [weak self] in
      self?.toastPanel?.orderOut(nil)
      self?.toastPanel = nil
    }
    toastHide = hide
    DispatchQueue.main.asyncAfter(
      deadline: .now() + seconds, execute: hide)
  }

  /// A rounded, softly glowing border on `rect` that fades in and
  /// out.
  func flash(_ rect: CGRect) {
    flashHide?.cancel()
    let p = flashPanel ?? Self.panel()
    flashPanel = p
    let glow: CGFloat = 10
    let border = CAShapeLayer()
    let box = CGRect(origin: .zero, size: rect.size).offsetBy(
      dx: glow, dy: glow
    ).insetBy(dx: 1.5, dy: 1.5)
    border.path = CGPath(
      roundedRect: box, cornerWidth: 14, cornerHeight: 14,
      transform: nil)
    border.fillColor = nil
    border.strokeColor = Panels.accent.cgColor
    border.lineWidth = 3
    border.shadowColor = Panels.accent.cgColor
    border.shadowRadius = 6
    border.shadowOpacity = 0.9
    border.shadowOffset = .zero
    let view = NSView()
    view.wantsLayer = true
    view.layer?.addSublayer(border)
    p.contentView = view
    p.setFrame(
      Screens.flip(rect).insetBy(dx: -glow, dy: -glow), display: true)
    p.alphaValue = 0
    p.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.08
      p.animator().alphaValue = 1
    }
    let hide = DispatchWorkItem {
      MainActor.assumeIsolated {
        NSAnimationContext.runAnimationGroup(
          { ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
          },
          completionHandler: {
            MainActor.assumeIsolated {
              if p.alphaValue == 0 { p.orderOut(nil) }
            }
          })
      }
    }
    flashHide = hide
    DispatchQueue.main.asyncAfter(
      deadline: .now() + 0.35, execute: hide)
  }

  /// Where a dragged window would land, tinted orange with what the
  /// drop does in words, and in a swap a faint outline where the
  /// other window goes; nil hides them.
  func showDrop(
    _ rect: CGRect?, caption: String = "", also: CGRect? = nil
  ) {
    guard let rect else {
      dropPanel?.orderOut(nil)
      swapPanel?.orderOut(nil)
      return
    }
    let p =
      dropPanel
      ?? Self.outline(
        width: 3, color: Panels.selection,
        fill: Panels.selection.withAlphaComponent(0.22))
    dropPanel = p
    p.contentView?.layer?.borderColor = Panels.selection.cgColor
    p.contentView?.layer?.backgroundColor =
      Panels.selection.withAlphaComponent(0.22).cgColor
    let pill =
      dropCaption
      ?? {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 10
        pill.addSubview(label)
        p.contentView?.addSubview(pill)
        return pill
      }()
    dropCaption = pill
    pill.layer?.backgroundColor = Panels.selection.cgColor
    (pill.subviews.first as? NSTextField)?.textColor = Panels.ink(
      on: Panels.selection)
    Self.show(p, rect)
    if let label = pill.subviews.first as? NSTextField,
      let box = p.contentView?.bounds
    {
      label.stringValue = caption
      let size = label.fittingSize
      pill.frame = NSRect(
        x: box.midX - size.width / 2 - 14,
        y: box.midY - size.height / 2 - 7,
        width: size.width + 28, height: size.height + 14)
      label.frame = NSRect(
        x: 14, y: 7, width: size.width, height: size.height)
      pill.isHidden = caption.isEmpty
    }
    if let also {
      let s =
        swapPanel
        ?? Self.outline(
          width: 2, color: Panels.selection.withAlphaComponent(0.7),
          fill: .clear)
      swapPanel = s
      s.contentView?.layer?.borderColor =
        Panels.selection.withAlphaComponent(0.7).cgColor
      Self.show(s, also)
    } else {
      swapPanel?.orderOut(nil)
    }
  }

  /// Click mode's labels, each at the left of what it presses, with
  /// the letters typed so far dimmed; none hides them.
  func showHints(
    _ hints: [(label: String, frame: CGRect)], typed: String = ""
  ) {
    guard
      let area = hints.map(\.frame).reduce(
        nil, { (u: CGRect?, r) in u?.union(r) ?? r })?.insetBy(
          dx: -30, dy: -30)
    else {
      hintPanel?.orderOut(nil)
      return
    }
    let p = hintPanel ?? Self.panel()
    hintPanel = p
    let view = p.contentView as? HintView ?? HintView()
    p.contentView = view
    view.origin = area.origin
    view.hints = hints
    view.typed = typed
    p.setFrame(Screens.flip(area), display: false)
    view.needsDisplay = true
    p.orderFrontRegardless()
  }

  private static func outline(
    width: CGFloat, color: NSColor, fill: NSColor
  ) -> NSPanel {
    let p = panel()
    let v = NSView()
    v.wantsLayer = true
    v.layer?.borderWidth = width
    v.layer?.cornerRadius = 12
    v.layer?.borderColor = color.cgColor
    v.layer?.backgroundColor = fill.cgColor
    p.contentView = v
    return p
  }

  private static func show(_ p: NSPanel, _ rect: CGRect) {
    let frame = Screens.flip(rect.insetBy(dx: 4, dy: 4))
    if p.frame != frame { p.setFrame(frame, display: true) }
    if !p.isVisible { p.orderFrontRegardless() }
  }

  private enum Place { case center, bottom }

  private func bubble(
    _ text: NSAttributedString, on screen: CGRect, at place: Place
  ) -> NSPanel {
    let label = NSTextField(labelWithAttributedString: text)
    label.maximumNumberOfLines = 0
    let size = label.fittingSize
    let pad: CGFloat = 18
    let box = NSSize(
      width: size.width + 2 * pad, height: size.height + 2 * pad)
    let x = screen.midX - box.width / 2
    let y =
      place == .center
      ? screen.midY - box.height / 2 : screen.maxY - box.height - 40
    let p = Self.panel()
    let content = NSView()
    label.frame = NSRect(
      x: pad, y: pad, width: size.width, height: size.height)
    content.addSubview(label)
    let glass = NSGlassEffectView()
    glass.cornerRadius = 14
    glass.contentView = content
    p.contentView = glass
    p.setFrame(
      Screens.flip(
        CGRect(x: x, y: y, width: box.width, height: box.height)),
      display: true)
    p.orderFrontRegardless()
    return p
  }

  private static func panel() -> NSPanel {
    Panels.overlay(level: .statusBar)
  }
}

/// The mode overlay's content: a title, then one column per group of
/// bindings.
final class ModeSheet: NSView {
  private struct Row {
    var cap: String; var label: String; var order: (Int, String)
  }
  private let title: String
  private var columns: [(title: String, rows: [Row])] = []
  private var back: [String] = []
  private static let capFont = NSFont.monospacedSystemFont(
    ofSize: 12, weight: .semibold)
  private static let labelFont = NSFont.systemFont(ofSize: 13)
  private static let headFont = NSFont.systemFont(
    ofSize: 11, weight: .semibold)
  private static let rowHeight: CGFloat = 24
  private static let pad: CGFloat = 18

  init(
    name: String, bindings: [KeySpec: [Command]],
    letters: Bool = false
  ) {
    title = L("\(Command.modeName(name)) mode")
    super.init(frame: .zero)
    var groups: [Command.Group: [Row]] = [:]
    if letters {
      groups[.focus] = [
        Row(
          cap: L("Letter"), label: L("Go to that window or tab"),
          order: (-1, ""))
      ]
    }
    for (key, commands) in bindings {
      if commands == [.mode("main")] || commands == [.mode("back")] {
        back.append(key.symbol)
        continue
      }
      // Entering the mode again locks it on (one_shot).
      let label =
        commands == [.mode(name)]
        ? L("Lock") : Command.label(of: commands)
      guard let label,
        let first = commands.first(where: { $0.label != nil })
      else { continue }
      groups[first.group, default: []].append(
        Row(
          cap: key.symbol, label: label,
          order: Self.order(first, label)))
    }
    back.sort { $0.count < $1.count }
    columns = Command.Group.allCases.compactMap { g in
      groups[g].map { (g.title, $0.sorted { $0.order < $1.order }) }
    }
    frame.size = fittingSize
  }

  init(title: String, rows: [(String, String)], back: [String]) {
    self.title = title
    super.init(frame: .zero)
    columns = [
      (
        L("Keys"),
        rows.enumerated().map {
          Row(
            cap: $0.element.0, label: $0.element.1,
            order: ($0.offset, ""))
        }
      )
    ]
    self.back = back
    frame.size = fittingSize
  }

  required init?(coder: NSCoder) { nil }

  override var isFlipped: Bool { true }

  /// Directions read left, down, up, right; screens by number; the
  /// rest alphabetically.
  private static func order(_ c: Command, _ label: String) -> (
    Int, String
  ) {
    let dirs: [Direction] = [.left, .down, .up, .right]
    switch c {
    case .focus(let d), .move(let d):
      return (dirs.firstIndex(of: d) ?? 0, "")
    case .focusMonitor(let n), .moveToMonitor(let n):
      return (10 + n, "")
    case .cycleMonitor(let s): return (s > 0 ? 20 : 21, "")
    default: return (100, label)
    }
  }

  private func width(_ s: String, _ f: NSFont) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: f]).width
  }

  private func columnWidth(_ rows: [Row], _ head: String) -> (
    cap: CGFloat, total: CGFloat
  ) {
    let cap =
      (rows.map { width($0.cap, Self.capFont) }.max() ?? 0) + 14
    let label =
      rows.map { width($0.label, Self.labelFont) }.max() ?? 0
    return (
      cap,
      max(cap + 8 + label, width(head.uppercased(), Self.headFont))
    )
  }

  override var fittingSize: NSSize {
    let widths = columns.map { columnWidth($0.rows, $0.title).total }
    let tallest = CGFloat(columns.map(\.rows.count).max() ?? 0)
    let w =
      widths.reduce(0, +) + CGFloat(max(columns.count - 1, 0)) * 26
      + 2 * Self.pad
    let h =
      Self.pad + 26 + 20 + tallest * Self.rowHeight
      + (back.isEmpty ? 0 : 30) + Self.pad - 4
    return NSSize(width: max(w, 220), height: h)
  }

  override func draw(_ dirtyRect: NSRect) {
    (title as NSString).draw(
      at: NSPoint(x: Self.pad, y: Self.pad - 2),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
        .foregroundColor: NSColor.labelColor
      ])
    var x = Self.pad
    let top = Self.pad + 30
    for column in columns {
      let (capW, total) = columnWidth(column.rows, column.title)
      (column.title.uppercased() as NSString).draw(
        at: NSPoint(x: x, y: top),
        withAttributes: [
          .font: Self.headFont, .foregroundColor: Panels.quiet,
          .kern: 0.6
        ])
      for (i, row) in column.rows.enumerated() {
        let y = top + 20 + CGFloat(i) * Self.rowHeight
        keycap(
          row.cap, NSRect(x: x, y: y + 2, width: capW, height: 19))
        (row.label as NSString).draw(
          at: NSPoint(x: x + capW + 8, y: y + 3),
          withAttributes: [
            .font: Self.labelFont,
            .foregroundColor: NSColor.labelColor
          ])
      }
      x += total + 26
    }
    if !back.isEmpty {
      let y = bounds.height - Self.pad - 16
      var bx = Self.pad
      for cap in back {
        let w = width(cap, Self.capFont) + 14
        keycap(cap, NSRect(x: bx, y: y - 2, width: w, height: 19))
        bx += w + 5
      }
      (L("back to tiling") as NSString).draw(
        at: NSPoint(x: bx + 4, y: y - 1),
        withAttributes: [
          .font: Self.labelFont, .foregroundColor: Panels.quiet
        ])
    }
  }

  private func keycap(_ text: String, _ r: NSRect) {
    NSColor.labelColor.withAlphaComponent(0.1).setFill()
    let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
    path.fill()
    NSColor.labelColor.withAlphaComponent(0.18).setStroke()
    path.lineWidth = 0.5
    path.stroke()
    let attrs: [NSAttributedString.Key: Any] = [
      .font: Self.capFont, .foregroundColor: NSColor.labelColor
    ]
    let s = (text as NSString).size(withAttributes: attrs)
    (text as NSString).draw(
      at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2),
      withAttributes: attrs)
  }
}

/// Click mode's labels: a small tag at the left edge of each element,
/// centered on it.
final class HintView: NSView {
  var origin = CGPoint.zero
  var hints: [(label: String, frame: CGRect)] = []
  var typed = ""

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    let ink = Panels.ink(on: Panels.accent)
    for h in hints {
      let text = NSMutableAttributedString(
        string: h.label.uppercased(),
        attributes: [.font: font, .foregroundColor: ink])
      text.addAttribute(
        .foregroundColor, value: ink.withAlphaComponent(0.45),
        range: NSRange(
          location: 0, length: min(typed.count, h.label.count)))
      let size = text.size()
      let r = NSRect(
        x: h.frame.minX - origin.x - 2,
        y: h.frame.midY - origin.y - (size.height + 4) / 2,
        width: size.width + 8, height: size.height + 4)
      let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
      Panels.accent.setFill()
      path.fill()
      ink.withAlphaComponent(0.7).setStroke()
      path.lineWidth = 1
      path.stroke()
      text.draw(at: NSPoint(x: r.minX + 4, y: r.minY + 2))
    }
  }
}
