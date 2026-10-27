import AppKit
import Layout

/// cmd-tab through tess. An event tap on a thread of its own (a busy main thread must never
/// hold up typing) takes cmd-tab before the Dock's switcher sees it. While cmd stays down, tab
/// and shift-tab (or the arrows) step, a letter goes to its window, esc cancels, and letting go
/// of cmd goes to the one picked. Every other key passes untouched.
final class CmdTab {
    enum Key { case open(back: Bool), step(back: Bool), letter(UInt16), cancel, release }

    /// Off while tess is paused: cmd-tab is macOS's again.
    // ponytail: a Bool written on main and read on the tap's thread; a lock if it grows.
    nonisolated(unsafe) static var enabled = true

    private let onKey: (Key) -> Void
    // The tap's thread only.
    private var tap: CFMachPort?
    private var open = false

    init(_ onKey: @escaping (Key) -> Void) {
        self.onKey = onKey
        let thread = Thread { [unowned self] in self.run() }
        thread.name = "tess.cmdtab"
        thread.start()
    }

    private func run() {
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, e, refcon in
            Unmanaged<CmdTab>.fromOpaque(refcon!).takeUnretainedValue().handle(type, e)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.write("cmd-tab: no event tap, macOS keeps it")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(e)
        // macOS turns a tap off when it answers slowly.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        let flags = e.flags, code = e.getIntegerValueField(.keyboardEventKeycode), back = flags.contains(.maskShift)
        if type == .flagsChanged {
            if open, !flags.contains(.maskCommand) {
                open = false
                send(.release)
            }
            return pass
        }
        if !open {
            guard Self.enabled, code == 48, flags.contains(.maskCommand), !flags.contains(.maskAlternate),
                  !flags.contains(.maskControl) else { return pass }
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
        default: send(.letter(UInt16(code)))
        }
        return nil
    }

    private func send(_ k: Key) { DispatchQueue.main.async { [onKey] in onKey(k) } }
}

/// The cmd-tab panel: a card per window, the picked one tinted, on the screen being looked at.
final class Switcher {
    struct Card {
        var id: WindowID
        var icon: NSImage?
        var app: String
        var title: String
        /// The screen it is on, when there is more than one.
        var detail: String
        var label: Character?
    }

    private(set) var cards: [Card] = []
    private(set) var selected = 0
    private var panel: NSPanel?
    private let view = SwitcherView()
    /// The picked window while the panel shows, nil once it closes: tess outlines it on screen.
    var onPick: (WindowID?) -> Void = { _ in }

    var pick: WindowID? { cards.indices.contains(selected) ? cards[selected].id : nil }

    func open(_ cards: [Card], selected: Int, on screen: CGRect) {
        self.cards = cards
        self.selected = selected
        // A quick cmd-tab goes without the panel flashing up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
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

    func close() {
        cards = []
        panel?.orderOut(nil)
        onPick(nil)
    }

    private func show(on screen: CGRect) {
        view.cards = cards
        view.selected = selected
        let p = panel ?? {
            let p = Panels.overlay(level: .statusBar)
            p.contentView = Panels.glass(view, radius: 22)
            return p
        }()
        panel = p
        let size = SwitcherView.size(for: cards.count, within: screen.width - 80)
        let r = CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        p.setFrame(Screens.flip(r), display: true)
        view.needsDisplay = true
        p.orderFrontRegardless()
        onPick(pick)
    }
}

final class SwitcherView: NSView {
    var cards: [Switcher.Card] = []
    var selected = 0
    static let card = NSSize(width: 168, height: 132)
    static let gap: CGFloat = 10, pad: CGFloat = 14

    override var isFlipped: Bool { true }

    static func columns(for n: Int, within width: CGFloat) -> Int {
        max(1, min(n, Int((width - 2 * pad + gap) / (card.width + gap))))
    }

    static func size(for n: Int, within width: CGFloat) -> NSSize {
        let cols = columns(for: n, within: width), rows = (n + cols - 1) / cols
        return NSSize(width: 2 * pad + CGFloat(cols) * card.width + CGFloat(cols - 1) * gap,
                      height: 2 * pad + CGFloat(rows) * card.height + CGFloat(rows - 1) * gap)
    }

    override func draw(_ dirtyRect: NSRect) {
        let cols = Self.columns(for: cards.count, within: bounds.width)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.lineBreakMode = .byTruncatingTail
        for (i, c) in cards.enumerated() {
            let r = NSRect(x: Self.pad + CGFloat(i % cols) * (Self.card.width + Self.gap),
                           y: Self.pad + CGFloat(i / cols) * (Self.card.height + Self.gap),
                           width: Self.card.width, height: Self.card.height)
            let path = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
            (i == selected ? Panels.accent.withAlphaComponent(0.28) : NSColor.labelColor.withAlphaComponent(0.05)).setFill()
            path.fill()
            if i == selected {
                Panels.accent.setStroke()
                path.lineWidth = 2
                path.stroke()
            }
            c.icon?.draw(in: NSRect(x: r.midX - 24, y: r.minY + 14, width: 48, height: 48))
            (c.app as NSString).draw(in: NSRect(x: r.minX + 8, y: r.minY + 68, width: r.width - 16, height: 17), withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: center,
            ])
            (c.title as NSString).draw(in: NSRect(x: r.minX + 8, y: r.minY + 87, width: r.width - 16, height: 15), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center,
            ])
            if !c.detail.isEmpty {
                (c.detail as NSString).draw(in: NSRect(x: r.minX + 8, y: r.minY + 106, width: r.width - 16, height: 14), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: center,
                ])
            }
            if let label = c.label { MapView.keycap(label, NSRect(x: r.minX + 8, y: r.minY + 8, width: 22, height: 22)) }
        }
    }
}
