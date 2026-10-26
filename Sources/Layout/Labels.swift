/// How keys and commands read in the UI (the mode overlay, the menu).

extension KeySpec {
    /// macOS notation: modifiers in Apple's order (⌃⌥⇧⌘), all four as ✦ (Hyper).
    public var symbol: String {
        let mods = mods.count == Mod.allCases.count ? "✦"
            : [(Mod.ctrl, "⌃"), (.alt, "⌥"), (.shift, "⇧"), (.cmd, "⌘")].filter { mods.contains($0.0) }.map(\.1).joined()
        return mods + (Self.symbols[key] ?? key.uppercased())
    }

    static let symbols: [String: String] = [
        "backspace": "⌫", "esc": "⎋", "enter": "↩", "tab": "⇥", "space": "Space",
        "left": "←", "down": "↓", "up": "↑", "right": "→",
        "minus": "-", "equal": "=", "slash": "/", "backslash": "\\", "semicolon": ";", "quote": "'",
        "backtick": "`", "comma": ",", "period": ".", "leftSquareBracket": "[", "rightSquareBracket": "]",
    ]
}

extension Command {
    public enum Group: Int, CaseIterable, Sendable {
        case focus, move, layout, more

        public var title: String {
            switch self {
            case .focus: "Focus"
            case .move: "Move"
            case .layout: "Layout"
            case .more: "More"
            }
        }
    }

    /// Plain words for the overlay and menus; nil for what is not worth showing.
    public var label: String? {
        switch self {
        case .focus(let d): "Focus \(d.rawValue)"
        case .move(let d): "Move \(d.rawValue)"
        case .resize(let a, let px):
            a == .width ? (px < 0 ? "Narrower" : "Wider") : (px < 0 ? "Shorter" : "Taller")
        case .balance: "Balance"
        case .flip: "Columns ↔ rows"
        case .accordion: "Accordion"
        case .fullscreen: "Fullscreen"
        case .nativeFullscreen: "macOS fullscreen"
        case .float: "Float"
        case .close: "Close window"
        case .focusMonitor(let n): "Screen \(n)"
        case .cycleMonitor(let s): s > 0 ? "Next screen" : "Previous screen"
        case .moveToMonitor(let n): "Move to screen \(n)"
        case .exec(let line):
            line.hasPrefix("open -a ") ? "Open \(line.dropFirst(8))" : "Run \(line)"
        case .reload: "Reload config"
        case .terminal: "New terminal"
        case .mode(let m): m == "main" || m == "back" ? "Back" : m == "tess" ? "tess mode" : "\(m.prefix(1).uppercased())\(m.dropFirst()) mode"
        case .retile: "Re-tile"
        case .rescue: "Rescue windows"
        case .pause: "Pause"
        case .pick: "Picker"
        case .closeReplace: "Close, pick a replacement"
        case .clearMonitor: "Clear this screen"
        case .settings: "Settings"
        case .jump: "Jump to a window"
        case .undo: "Undo"
        case .redo: "Redo"
        case .zen: "Zen"
        case .focusWindow: "Go to a window"
        case .swapWith: "Swap windows"
        case .tree, .nop, .debugMap, .state: nil
        }
    }

    public var group: Group {
        switch self {
        case .focus, .focusMonitor, .cycleMonitor, .jump: .focus
        case .move, .moveToMonitor, .clearMonitor: .move
        case .resize, .balance, .flip, .accordion, .fullscreen, .nativeFullscreen, .float: .layout
        default: .more
        }
    }

    /// A binding's label: its first command that says something ("retile; mode main" is "Re-tile").
    public static func label(of commands: [Command]) -> String? {
        commands.first { if case .mode = $0 { return commands.count == 1 }; return $0.label != nil }?.label
    }
}

/// Labels that stay with their windows: windows keep their letter while they live, and new
/// windows take the first free letters, in `windows` order. Past the alphabet, none.
public func stableLabels(_ current: [WindowID: Character], windows: [WindowID], alphabet: String) -> [WindowID: Character] {
    let alive = Set(windows)
    var out = current.filter { alive.contains($0.key) }
    var free = alphabet.filter { c in !out.values.contains(c) }
    for id in windows where out[id] == nil {
        guard !free.isEmpty else { break }
        out[id] = free.removeFirst()
    }
    return out
}
