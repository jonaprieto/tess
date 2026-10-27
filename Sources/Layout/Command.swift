import Foundation

public struct ParseError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// A change to the speakers' volume.
public enum Volume: Equatable, Sendable {
    /// From 0 to 100; up or down by that much; muted or not.
    case level(Int), step(Int), mute, unmute

    /// As the config and the CLI write it, after `volume`.
    public var word: String {
        switch self {
        case .level(let n): "\(n)"
        case .step(let n): n >= 0 ? "+\(n)" : "\(n)"
        case .mute: "mute"
        case .unmute: "unmute"
        }
    }
}

public enum Command: Equatable, Sendable {
    case focus(Direction), move(Direction), resize(Axis, Double)
    /// Bigger or smaller along the lanes' axis: wider in columns, taller in rows (`grow +50`).
    case grow(Double)
    case balance, flip, accordion, fullscreen, nativeFullscreen, float, close
    /// Every window on the active monitor in one shape (`halves`, `columns`, `rows`, `grid`).
    case arrange(Arrangement)
    /// Monitor numbers as written, from 1.
    case focusMonitor(Int), cycleMonitor(Int), moveToMonitor(Int)
    /// The next or previous window, across screens (`focus next`, `focus prev`).
    case cycleWindow(Int)
    /// The speakers (`volume 30`, `volume +10`, `volume mute`).
    case volume(Volume)
    /// Wi-Fi on, off, or (nil) the other way round (`wifi on`, `wifi`).
    case wifi(Bool?)
    /// The Mac kept awake for that many minutes, until turned off (nil, `caffeine`, which
    /// turns it off when it is on), or no longer (0, `caffeine off`).
    case caffeine(Int?)
    case exec(String), reload, mode(String), retile, rescue, pause, tree, nop
    /// A new window of the config's terminal, in the home folder.
    case terminal
    /// The picker; close the focused window and pick what fills its place.
    case pick(String), closeReplace
    /// Send every window on the active monitor to the next one.
    case clearMonitor
    /// The settings window.
    case settings
    /// tess's model and the machine, as JSON (also written to the event log).
    case state
    /// Jump mode: every window's label and screen number as a key.
    case jump
    /// A window by its id (what jump mode binds to labels).
    case focusWindow(UInt32), swapWith(UInt32)
    /// A tab by its place among the tabs tess labeled (what tess mode and jump mode bind to
    /// tab letters).
    case focusTab(Int)
    /// Back to the layout before the last change made with a key, the CLI or the picker, and
    /// forward again.
    case undo, redo
    /// The focused window alone in front, with a pomodoro timer, until run again.
    case zen
    /// Renders the picker's map to a PNG at this path (for debugging without a screen).
    case debugMap(String)

    /// The commands that take no argument, by name.
    public static let simple: [String: Command] = [
        "balance": .balance, "flip": .flip, "accordion": .accordion, "fullscreen": .fullscreen,
        "native-fullscreen": .nativeFullscreen, "float": .float, "close": .close, "reload": .reload,
        "retile": .retile, "rescue": .rescue, "pause": .pause, "tree": .tree, "nop": .nop,
        "pick": .pick(""), "close-replace": .closeReplace, "clear-screen": .clearMonitor, "settings": .settings, "state": .state, "jump": .jump,
        "undo": .undo, "redo": .redo, "zen": .zen, "terminal": .terminal,
        "wifi": .wifi(nil), "caffeine": .caffeine(nil),
        "halves": .arrange(.halves), "columns": .arrange(.columns), "rows": .arrange(.rows), "grid": .arrange(.grid),
    ]

    /// Commands separated by `;`. `exec` takes the rest of the line, `;` included.
    public static func parse(_ line: String) throws -> [Command] {
        var out: [Command] = []
        var rest = Substring(line)
        while true {
            let part = rest.drop(while: \.isWhitespace)
            if part.hasPrefix("debug-map ") {
                out.append(.debugMap(part.dropFirst(10).trimmingCharacters(in: .whitespaces)))
                return out
            }
            if part.hasPrefix("pick ") {
                // Like exec, the rest of the line: the text the picker starts with.
                out.append(.pick(part.dropFirst(5).trimmingCharacters(in: .whitespaces)))
                return out
            }
            if part == "exec" || part.hasPrefix("exec ") {
                let cmd = part.dropFirst(4).trimmingCharacters(in: .whitespaces)
                guard !cmd.isEmpty else { throw ParseError("exec needs a shell command") }
                out.append(.exec(cmd))
                return out
            }
            let semi = part.firstIndex(of: ";")
            out.append(try one(part[..<(semi ?? part.endIndex)]))
            guard let semi else { return out }
            rest = part[part.index(after: semi)...]
        }
    }

    static func one(_ text: Substring) throws -> Command {
        let w = text.split(separator: " ").map(String.init)
        let bad = ParseError("unknown command '\(text.trimmingCharacters(in: .whitespaces))'")
        guard let head = w.first else { throw ParseError("empty command") }
        if w.count == 1, let c = simple[head] { return c }
        func monitor(_ s: String) throws -> Int {
            guard let n = Int(s), n >= 1 else { throw bad }
            return n
        }
        func direction(_ s: String) throws -> Direction {
            guard let d = Direction(rawValue: s) else { throw bad }
            return d
        }
        switch (head, w.count) {
        case ("focus", 2):
            switch w[1] {
            case "next": return .cycleWindow(1)
            case "prev": return .cycleWindow(-1)
            default: return .focus(try direction(w[1]))
            }
        case ("move", 2): return .move(try direction(w[1]))
        case ("resize", 3):
            guard let axis = Axis(rawValue: w[1]), let px = Double(w[2]), px.isFinite else { throw bad }
            return .resize(axis, min(max(px, -10_000), 10_000))
        case ("volume", 2):
            switch w[1] {
            case "mute": return .volume(.mute)
            case "unmute": return .volume(.unmute)
            default:
                guard let n = Int(w[1]) else { throw bad }
                let signed = w[1].hasPrefix("+") || w[1].hasPrefix("-")
                return .volume(signed ? .step(min(max(n, -100), 100)) : .level(min(max(n, 0), 100)))
            }
        case ("wifi", 2):
            guard w[1] == "on" || w[1] == "off" else { throw bad }
            return .wifi(w[1] == "on")
        case ("caffeine", 2):
            if w[1] == "off" { return .caffeine(0) }
            guard let n = Int(w[1]), n > 0 else { throw bad }
            return .caffeine(min(n, 24 * 60))
        case ("grow", 2):
            guard let px = Double(w[1]), px.isFinite else { throw bad }
            return .grow(min(max(px, -10_000), 10_000))
        case ("focus-screen", 2):
            switch w[1] {
            case "next": return .cycleMonitor(1)
            case "prev": return .cycleMonitor(-1)
            default: return .focusMonitor(try monitor(w[1]))
            }
        case ("move-to-screen", 2): return .moveToMonitor(try monitor(w[1]))
        case ("mode", 2): return .mode(w[1])
        case ("focus-window", 2), ("swap-with", 2):
            guard let id = UInt32(w[1]) else { throw bad }
            return head == "focus-window" ? .focusWindow(id) : .swapWith(id)
        case ("focus-tab", 2):
            guard let n = Int(w[1]), n >= 0 else { throw bad }
            return .focusTab(n)
        default: throw bad
        }
    }
}

public enum Mod: String, CaseIterable, Sendable, Hashable {
    case cmd, alt, ctrl, shift
}

/// A key with modifiers, written like `alt-shift-h`.
public struct KeySpec: Hashable, Sendable, CustomStringConvertible {
    public var key: String
    public var mods: Set<Mod>

    public init(key: String, mods: Set<Mod>) {
        self.key = key
        self.mods = mods
    }

    public static let keys: Set<String> = Set(
        "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init) + (1...20).map { "f\($0)" } + [
            "minus", "equal", "period", "comma", "slash", "backslash", "quote", "semicolon", "backtick",
            "leftSquareBracket", "rightSquareBracket", "space", "enter", "esc", "backspace", "tab",
            "left", "down", "up", "right",
        ])

    public static func parse(_ s: String) throws -> KeySpec {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, keys.contains(key) else { throw ParseError("unknown key in '\(s)'") }
        var mods = Set<Mod>()
        for p in parts.dropLast() {
            guard let m = Mod(rawValue: p), mods.insert(m).inserted else { throw ParseError("bad modifier '\(p)' in '\(s)'") }
        }
        return KeySpec(key: key, mods: mods)
    }

    public var description: String {
        (Mod.allCases.filter(mods.contains).map(\.rawValue) + [key]).joined(separator: "-")
    }
}

extension Command {
    /// Moves or resizes a tiled window.
    public var isMoveOrResize: Bool {
        switch self {
        case .move, .resize, .grow: true
        default: false
        }
    }
}

extension Command: CustomStringConvertible {
    /// The command as written in the config; `parse` reads it back.
    public var description: String {
        switch self {
        case .focus(let d): "focus \(d.rawValue)"
        case .move(let d): "move \(d.rawValue)"
        case .resize(let a, let px): "resize \(a.rawValue) \(px >= 0 ? "+" : "")\(px == px.rounded() ? String(Int(px)) : String(px))"
        case .grow(let px): "grow \(px >= 0 ? "+" : "")\(px == px.rounded() ? String(Int(px)) : String(px))"
        case .focusMonitor(let n): "focus-screen \(n)"
        case .cycleMonitor(let s): "focus-screen \(s > 0 ? "next" : "prev")"
        case .cycleWindow(let s): "focus \(s > 0 ? "next" : "prev")"
        case .volume(let v): "volume \(v.word)"
        case .wifi(let on?): "wifi \(on ? "on" : "off")"
        case .caffeine(let m?): m == 0 ? "caffeine off" : "caffeine \(m)"
        case .moveToMonitor(let n): "move-to-screen \(n)"
        case .clearMonitor: "clear-screen"
        case .exec(let s): "exec \(s)"
        case .mode(let m): "mode \(m)"
        case .pick(let text): text.isEmpty ? "pick" : "pick \(text)"
        case .debugMap(let path): "debug-map \(path)"
        case .focusWindow(let id): "focus-window \(id)"
        case .swapWith(let id): "swap-with \(id)"
        case .focusTab(let n): "focus-tab \(n)"
        default: Command.simple.first { $0.value == self }?.key ?? "nop"
        }
    }
}
