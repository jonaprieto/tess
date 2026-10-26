import AppKit
import Layout

/// On-screen feedback: the keys of the current mode, a border flash on the focused window,
/// and short toasts. Click-through panels above all windows that never take focus.
/// Rects are in AX coordinates (top-left origin), like everything else in tess.
final class Overlay {
    private var modePanels: [NSPanel] = []
    private var toastPanel: NSPanel?
    private var flashPanel: NSPanel?
    private var dropPanel: NSPanel?
    private var toastHide: DispatchWorkItem?
    private var flashHide: DispatchWorkItem?

    /// The keys of a mode as a glass cheat sheet in the bottom-right corner of each of `screens`:
    /// grouped columns of keycaps and plain labels, so the windows being arranged stay visible.
    func showMode(_ name: String, _ bindings: [KeySpec: [Command]], on screens: [CGRect]) {
        show(on: screens) { ModeSheet(name: name, bindings: bindings) }
    }

    /// A sheet with given rows, for jump mode, whose keys are the window letters.
    func showSheet(_ title: String, rows: [(String, String)], back: [String], on screens: [CGRect]) {
        show(on: screens) { ModeSheet(title: title, rows: rows, back: back) }
    }

    private func show(on screens: [CGRect], _ make: () -> ModeSheet) {
        hideMode()
        for screen in screens {
            let view = make()
            let size = view.fittingSize
            let r = CGRect(x: screen.maxX - size.width - 24, y: screen.maxY - size.height - 24, width: size.width, height: size.height)
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

    func toast(_ message: String, on screen: CGRect) {
        toastHide?.cancel()
        toastPanel?.orderOut(nil)
        toastPanel = bubble(NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.labelColor,
        ]), on: screen, at: .bottom)
        let hide = DispatchWorkItem { [weak self] in
            self?.toastPanel?.orderOut(nil)
            self?.toastPanel = nil
        }
        toastHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: hide)
    }

    /// A rounded, softly glowing border on `rect` that fades in and out.
    func flash(_ rect: CGRect) {
        flashHide?.cancel()
        let p = flashPanel ?? Self.panel()
        flashPanel = p
        let glow: CGFloat = 10
        let border = CAShapeLayer()
        let box = CGRect(origin: .zero, size: rect.size).offsetBy(dx: glow, dy: glow).insetBy(dx: 1.5, dy: 1.5)
        border.path = CGPath(roundedRect: box, cornerWidth: 14, cornerHeight: 14, transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.controlAccentColor.cgColor
        border.lineWidth = 3
        border.shadowColor = NSColor.controlAccentColor.cgColor
        border.shadowRadius = 6
        border.shadowOpacity = 0.9
        border.shadowOffset = .zero
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(border)
        p.contentView = view
        p.setFrame(Screens.flip(rect).insetBy(dx: -glow, dy: -glow), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            p.animator().alphaValue = 1
        }
        let hide = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: { if p.alphaValue == 0 { p.orderOut(nil) } })
        }
        flashHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: hide)
    }

    /// Where a dragged window would land, tinted; nil hides it.
    func showDrop(_ rect: CGRect?) {
        guard let rect else {
            dropPanel?.orderOut(nil)
            return
        }
        let p = dropPanel ?? {
            let p = Self.panel()
            let v = NSView()
            v.wantsLayer = true
            v.layer?.borderWidth = 3
            v.layer?.cornerRadius = 12
            p.contentView = v
            return p
        }()
        dropPanel = p
        p.contentView?.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        p.contentView?.layer?.borderColor = NSColor.controlAccentColor.cgColor
        let frame = Screens.flip(rect.insetBy(dx: 4, dy: 4))
        if p.frame != frame { p.setFrame(frame, display: true) }
        if !p.isVisible { p.orderFrontRegardless() }
    }

    private enum Place { case center, bottom }

    private func bubble(_ text: NSAttributedString, on screen: CGRect, at place: Place) -> NSPanel {
        let label = NSTextField(labelWithAttributedString: text)
        label.maximumNumberOfLines = 0
        let size = label.fittingSize
        let pad: CGFloat = 18
        let box = NSSize(width: size.width + 2 * pad, height: size.height + 2 * pad)
        let x = screen.midX - box.width / 2
        let y = place == .center ? screen.midY - box.height / 2 : screen.maxY - box.height - 40
        let p = Self.panel()
        let content = NSView()
        label.frame = NSRect(x: pad, y: pad, width: size.width, height: size.height)
        content.addSubview(label)
        let glass = NSGlassEffectView()
        glass.cornerRadius = 14
        glass.contentView = content
        p.contentView = glass
        p.setFrame(Screens.flip(CGRect(x: x, y: y, width: box.width, height: box.height)), display: true)
        p.orderFrontRegardless()
        return p
    }

    private static func panel() -> NSPanel { Panels.overlay(level: .statusBar) }
}

/// The mode overlay's content: a title, then one column per group of bindings.
final class ModeSheet: NSView {
    private struct Row { var cap: String; var label: String; var order: (Int, String) }
    private let title: String
    private var columns: [(title: String, rows: [Row])] = []
    private var back: [String] = []
    private static let capFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
    private static let labelFont = NSFont.systemFont(ofSize: 13)
    private static let headFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private static let rowHeight: CGFloat = 24
    private static let pad: CGFloat = 18

    init(name: String, bindings: [KeySpec: [Command]]) {
        title = name == "tess" ? "tess mode" : "\(name.prefix(1).uppercased())\(name.dropFirst()) mode"
        super.init(frame: .zero)
        var groups: [Command.Group: [Row]] = [:]
        for (key, commands) in bindings {
            if commands == [.mode("main")] || commands == [.mode("back")] {
                back.append(key.symbol)
                continue
            }
            // Entering the mode again locks it on (one_shot).
            let label = commands == [.mode(name)] ? "Lock" : Command.label(of: commands)
            guard let label, let first = commands.first(where: { $0.label != nil }) else { continue }
            groups[first.group, default: []].append(Row(cap: key.symbol, label: label, order: Self.order(first, label)))
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
        columns = [("Keys", rows.enumerated().map { Row(cap: $0.element.0, label: $0.element.1, order: ($0.offset, "")) })]
        self.back = back
        frame.size = fittingSize
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Directions read left, down, up, right; screens by number; the rest alphabetically.
    private static func order(_ c: Command, _ label: String) -> (Int, String) {
        let dirs: [Direction] = [.left, .down, .up, .right]
        switch c {
        case .focus(let d), .move(let d): return (dirs.firstIndex(of: d) ?? 0, "")
        case .focusMonitor(let n), .moveToMonitor(let n): return (10 + n, "")
        case .cycleMonitor(let s): return (s > 0 ? 20 : 21, "")
        default: return (100, label)
        }
    }

    private func width(_ s: String, _ f: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: f]).width }

    private func columnWidth(_ rows: [Row], _ head: String) -> (cap: CGFloat, total: CGFloat) {
        let cap = (rows.map { width($0.cap, Self.capFont) }.max() ?? 0) + 14
        let label = rows.map { width($0.label, Self.labelFont) }.max() ?? 0
        return (cap, max(cap + 8 + label, width(head.uppercased(), Self.headFont)))
    }

    override var fittingSize: NSSize {
        let widths = columns.map { columnWidth($0.rows, $0.title).total }
        let tallest = CGFloat(columns.map(\.rows.count).max() ?? 0)
        let w = widths.reduce(0, +) + CGFloat(max(columns.count - 1, 0)) * 26 + 2 * Self.pad
        let h = Self.pad + 26 + 20 + tallest * Self.rowHeight + (back.isEmpty ? 0 : 30) + Self.pad - 4
        return NSSize(width: max(w, 220), height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        (title as NSString).draw(at: NSPoint(x: Self.pad, y: Self.pad - 2), withAttributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ])
        var x = Self.pad
        let top = Self.pad + 30
        for column in columns {
            let (capW, total) = columnWidth(column.rows, column.title)
            (column.title.uppercased() as NSString).draw(at: NSPoint(x: x, y: top), withAttributes: [
                .font: Self.headFont, .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.6,
            ])
            for (i, row) in column.rows.enumerated() {
                let y = top + 20 + CGFloat(i) * Self.rowHeight
                keycap(row.cap, NSRect(x: x, y: y + 2, width: capW, height: 19))
                (row.label as NSString).draw(at: NSPoint(x: x + capW + 8, y: y + 3), withAttributes: [
                    .font: Self.labelFont, .foregroundColor: NSColor.labelColor,
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
            ("back to tiling" as NSString).draw(at: NSPoint(x: bx + 4, y: y - 1), withAttributes: [
                .font: Self.labelFont, .foregroundColor: NSColor.secondaryLabelColor,
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
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.capFont, .foregroundColor: NSColor.labelColor]
        let s = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: attrs)
    }
}
