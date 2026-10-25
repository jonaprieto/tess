import AppKit

/// On-screen feedback: the keys of the current mode, a border flash on the focused window,
/// and short toasts. Click-through panels above all windows that never take focus.
/// Rects are in AX coordinates (top-left origin), like everything else in tess.
final class Overlay {
    private var modePanel: NSPanel?
    private var toastPanel: NSPanel?
    private var flashPanel: NSPanel?
    private var toastHide: DispatchWorkItem?
    private var flashHide: DispatchWorkItem?

    func showMode(_ name: String, _ rows: [(key: String, command: String)], on screen: CGRect) {
        let width = rows.map(\.key.count).max() ?? 0
        let text = NSMutableAttributedString(string: name + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ])
        for r in rows {
            text.append(NSAttributedString(string: "\n" + r.key.padding(toLength: width + 3, withPad: " ", startingAt: 0), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), .foregroundColor: NSColor.controlAccentColor,
            ]))
            text.append(NSAttributedString(string: r.command, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.labelColor,
            ]))
        }
        modePanel?.orderOut(nil)
        modePanel = bubble(text, on: screen, at: .center)
    }

    func hideMode() {
        modePanel?.orderOut(nil)
        modePanel = nil
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
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        label.frame = NSRect(x: pad, y: pad, width: size.width, height: size.height)
        bg.addSubview(label)
        p.contentView = bg
        p.setFrame(Screens.flip(CGRect(x: x, y: y, width: box.width, height: box.height)), display: true)
        p.orderFrontRegardless()
        return p
    }

    private static func panel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return p
    }
}
