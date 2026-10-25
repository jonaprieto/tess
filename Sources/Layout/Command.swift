import Foundation

public struct ParseError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum Command: Equatable, Sendable {
    case focus(Direction), move(Direction), resize(Axis, Double)
    case balance, flip, accordion, fullscreen, nativeFullscreen, float, close
    /// Monitor numbers as written, from 1.
    case focusMonitor(Int), cycleMonitor(Int), moveToMonitor(Int)
    case exec(String), reload, mode(String), retile, rescue, pause, tree, nop
    /// The picker; close the focused window and pick what fills its place.
    case pick(String), closeReplace
    /// Send every window on the active monitor to the next one.
    case clearMonitor
    /// The settings window.
    case settings
    /// Renders the picker's map to a PNG at this path (for debugging without a screen).
    case debugMap(String)

    static let simple: [String: Command] = [
        "balance": .balance, "flip": .flip, "accordion": .accordion, "fullscreen": .fullscreen,
        "native-fullscreen": .nativeFullscreen, "float": .float, "close": .close, "reload": .reload,
        "retile": .retile, "rescue": .rescue, "pause": .pause, "tree": .tree, "nop": .nop,
        "pick": .pick(""), "close-replace": .closeReplace, "clear-monitor": .clearMonitor, "settings": .settings,
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
        case ("focus", 2): return .focus(try direction(w[1]))
        case ("move", 2): return .move(try direction(w[1]))
        case ("resize", 3):
            guard let axis = Axis(rawValue: w[1]), let px = Double(w[2]) else { throw bad }
            return .resize(axis, px)
        case ("focus-monitor", 2):
            switch w[1] {
            case "next": return .cycleMonitor(1)
            case "prev": return .cycleMonitor(-1)
            default: return .focusMonitor(try monitor(w[1]))
            }
        case ("move-to-monitor", 2): return .moveToMonitor(try monitor(w[1]))
        case ("mode", 2): return .mode(w[1])
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

extension Command: CustomStringConvertible {
    /// The command as written in the config; `parse` reads it back.
    public var description: String {
        switch self {
        case .focus(let d): "focus \(d.rawValue)"
        case .move(let d): "move \(d.rawValue)"
        case .resize(let a, let px): "resize \(a.rawValue) \(px >= 0 ? "+" : "")\(px == px.rounded() ? String(Int(px)) : String(px))"
        case .focusMonitor(let n): "focus-monitor \(n)"
        case .cycleMonitor(let s): "focus-monitor \(s > 0 ? "next" : "prev")"
        case .moveToMonitor(let n): "move-to-monitor \(n)"
        case .exec(let s): "exec \(s)"
        case .mode(let m): "mode \(m)"
        case .pick(let text): text.isEmpty ? "pick" : "pick \(text)"
        case .debugMap(let path): "debug-map \(path)"
        default: Command.simple.first { $0.value == self }?.key ?? "nop"
        }
    }
}
