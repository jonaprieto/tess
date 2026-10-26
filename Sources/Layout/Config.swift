import Foundation

/// The built-in defaults with `~/.config/tess/config.json` on top: gaps and app lists in
/// the file replace the defaults, verbs and key bindings merge key by key, and a `null`
/// removes a default. New defaults therefore reach an existing file.
public struct Config: Equatable, Sendable {
    public var inner: Double = 10
    public var outer: Double = 10
    /// Bundle ids whose windows float.
    public var float: [String] = []
    /// Bundle ids whose windows tile even without a fullscreen button.
    public var tile: [String] = []
    /// Bundle ids tess never touches.
    public var ignore: [String] = []
    /// Picker verbs: `cd ~/x` opens the folder with the app named here.
    public var verbs: [String: String] = [:]
    /// The keys of a mode on every screen, rather than only the one being worked on.
    public var overlayAllScreens = true
    /// When windows show their border and letter, and screens their number.
    public var windowLabels = LabelMode.jump
    /// New windows go to an empty screen when there is one, and the settings window and a
    /// mode's keys show on the screen with the fewest windows (instead of `overlayAllScreens`).
    public var emptyScreens = true

    public enum LabelMode: String, Codable, Sendable {
        /// Always on screen.
        case always
        /// Only in jump mode, while they are keys.
        case jump
        case off
    }
    /// Mode -> key -> commands. `main` is where tess starts.
    public var modes: [String: [KeySpec: [Command]]] = [:]
    /// The merged config as written, for the settings window.
    public var raw = Raw()

    /// The config as JSON: every field optional, so a file can hold only what it changes.
    public struct Raw: Codable, Equatable, Sendable {
        public struct Gaps: Codable, Equatable, Sendable {
            public var inner: Double?, outer: Double?
            public init(inner: Double? = nil, outer: Double? = nil) {
                self.inner = inner
                self.outer = outer
            }
        }
        public struct Overlay: Codable, Equatable, Sendable {
            public var allScreens: Bool?
            public var windowLabels: LabelMode?
            enum CodingKeys: String, CodingKey {
                case allScreens = "all_screens"
                case windowLabels = "window_labels"
            }
            public init(allScreens: Bool? = nil, windowLabels: LabelMode? = nil) {
                self.allScreens = allScreens
                self.windowLabels = windowLabels
            }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                allScreens = try c.decodeIfPresent(Bool.self, forKey: .allScreens)
                // "always", "jump" or "off"; the earlier true/false still reads.
                if let on = try? c.decodeIfPresent(Bool.self, forKey: .windowLabels) {
                    windowLabels = on ? .always : .off
                } else if let s = try c.decodeIfPresent(String.self, forKey: .windowLabels) {
                    guard let mode = LabelMode(rawValue: s) else {
                        throw ParseError("config: overlay.window_labels is \"always\", \"jump\" or \"off\", not \"\(s)\"")
                    }
                    windowLabels = mode
                }
            }
        }
        public var gaps: Gaps?
        public var overlay: Overlay?
        public var float: [String]?
        public var tile: [String]?
        public var ignore: [String]?
        public var verbs: [String: String?]?
        public var modes: [String: [String: String?]]?
        public var emptyScreens: Bool?
        enum CodingKeys: String, CodingKey {
            case gaps, overlay, float, tile, ignore, verbs, modes
            case emptyScreens = "empty_screens"
        }
        public init() {}
    }

    public static func load(_ file: Data?) throws -> Config {
        guard let file else { return try build(defaultRaw) }
        return try build(merged(defaultRaw, decodeRaw(file)))
    }

    static func decodeRaw(_ data: Data) throws -> Raw {
        do {
            return try JSONDecoder().decode(Raw.self, from: data)
        } catch let DecodingError.dataCorrupted(ctx) {
            throw ParseError("config is not valid JSON: \(ctx.underlyingError.map { "\($0)" } ?? ctx.debugDescription)")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw ParseError("config: wrong type at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch let e as ParseError {
            throw e
        } catch let DecodingError.valueNotFound(_, ctx) {
            throw ParseError("config: missing value at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
        }
    }

    /// A binding key as `KeySpec` writes it, so `shift-alt-h` and `alt-shift-h` are one key.
    static func canonical(_ bindings: [String: String?]?) -> [String: String?]? {
        bindings.map { b in
            Dictionary(b.map { ((try? KeySpec.parse($0.key))?.description ?? $0.key, $0.value) }) { _, last in last }
        }
    }

    /// `top` over `base`; the result has no nulls left.
    public static func merged(_ base: Raw, _ top: Raw) -> Raw {
        func merge(_ b: [String: String?]?, _ t: [String: String?]?) -> [String: String?]? {
            guard let t else { return b }
            var out = b ?? [:]
            for (k, v) in t { out[k] = v.map { .some($0) } ?? nil }
            return out.filter { $0.value != nil }
        }
        var r = base
        if let g = top.gaps { r.gaps = Raw.Gaps(inner: g.inner ?? base.gaps?.inner, outer: g.outer ?? base.gaps?.outer) }
        r.overlay = Raw.Overlay(allScreens: top.overlay?.allScreens ?? base.overlay?.allScreens,
                                windowLabels: top.overlay?.windowLabels ?? base.overlay?.windowLabels)
        r.emptyScreens = top.emptyScreens ?? base.emptyScreens
        r.float = top.float ?? base.float
        r.tile = top.tile ?? base.tile
        r.ignore = top.ignore ?? base.ignore
        r.verbs = merge(base.verbs, top.verbs)
        var modes = (base.modes ?? [:]).mapValues { canonical($0) ?? [:] }
        // tess mode was called "wm" before; a file that still says so means tess mode.
        for (m, bindings) in top.modes ?? [:] {
            let name = m == "wm" ? "tess" : m
            modes[name] = merge(modes[name], canonical(bindings))
        }
        r.modes = modes
        return r
    }

    /// What `edited` changes relative to `base`, as a file would hold it (removals as null).
    public static func overrides(_ edited: Raw, over base: Raw) -> Raw {
        func diff(_ e: [String: String?]?, _ b: [String: String?]?) -> [String: String?]? {
            var out: [String: String?] = [:]
            for (k, v) in e ?? [:] where b?[k] != v { out[k] = v }
            for (k, _) in b ?? [:] where e?[k] == nil { out[k] = .some(nil) }
            return out.isEmpty ? nil : out
        }
        var o = Raw()
        if edited.gaps != base.gaps { o.gaps = edited.gaps }
        if edited.overlay != base.overlay { o.overlay = edited.overlay }
        if edited.emptyScreens != base.emptyScreens { o.emptyScreens = edited.emptyScreens }
        if edited.float != base.float { o.float = edited.float }
        if edited.tile != base.tile { o.tile = edited.tile }
        if edited.ignore != base.ignore { o.ignore = edited.ignore }
        o.verbs = diff(edited.verbs, base.verbs)
        var modes: [String: [String: String?]] = [:]
        for m in Set((edited.modes ?? [:]).keys).union((base.modes ?? [:]).keys) {
            if let d = diff(canonical(edited.modes?[m]), canonical(base.modes?[m])) { modes[m] = d }
        }
        o.modes = modes.isEmpty ? nil : modes
        return o
    }

    /// The file for `edited`: only its differences from the defaults, keys sorted.
    public static func file(for edited: Raw) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(overrides(edited, over: defaultRaw))
    }

    /// The config `raw` describes, or the first problem in it.
    public static func validate(_ raw: Raw) throws -> Config { try build(raw) }

    static func build(_ raw: Raw) throws -> Config {
        var c = Config()
        c.raw = raw
        // Whole points within reason: half points alternate 2 and 3 pt gaps, and an outer gap
        // larger than half a screen leaves no area at all.
        c.inner = min(max(raw.gaps?.inner ?? 10, 0), 100).rounded()
        c.outer = min(max(raw.gaps?.outer ?? 10, 0), 100).rounded()
        c.overlayAllScreens = raw.overlay?.allScreens ?? true
        c.windowLabels = raw.overlay?.windowLabels ?? .jump
        c.emptyScreens = raw.emptyScreens ?? true
        c.float = raw.float ?? []
        c.tile = raw.tile ?? []
        c.ignore = raw.ignore ?? []
        c.verbs = (raw.verbs ?? [:]).compactMapValues { $0 }
        let modes = raw.modes ?? [:]
        guard modes["main"] != nil else { throw ParseError("config: modes.main is missing") }
        for (mode, bindings) in modes {
            var parsed: [KeySpec: [Command]] = [:]
            for (key, line) in bindings {
                guard let line else { continue }
                do {
                    let commands = try Command.parse(line)
                    // "back" is the mode the current one was entered from.
                    for case .mode(let m) in commands where modes[m] == nil && m != "back" {
                        throw ParseError("no mode '\(m)'")
                    }
                    parsed[try KeySpec.parse(key)] = commands
                } catch {
                    throw ParseError("config: modes.\(mode).\(key): \(error)")
                }
            }
            c.modes[mode] = parsed
        }
        return c
    }

    // swift-format-ignore
    public static let defaultJSON = #"""
    {
      "gaps": {"inner": 10, "outer": 10},
      "overlay": {"all_screens": true, "window_labels": "jump"},
      "empty_screens": true,
      "float": ["com.apple.systempreferences", "com.apple.ActivityMonitor", "com.apple.calculator", "com.apple.finder"],
      "tile": ["com.anthropic.claudefordesktop"],
      "ignore": ["io.github.ender-wang.EdgeMark"],
      "verbs": {"cd": "iTerm", "code": "Visual Studio Code"},
      "modes": {
        "main": {
          "alt-h": "focus left",
          "alt-j": "focus down",
          "alt-k": "focus up",
          "alt-l": "focus right",
          "alt-shift-h": "move left",
          "alt-shift-j": "move down",
          "alt-shift-k": "move up",
          "alt-shift-l": "move right",
          "alt-slash": "flip",
          "alt-shift-slash": "accordion",
          "alt-shift-minus": "resize width -50",
          "alt-shift-equal": "resize width +50",
          "alt-shift-0": "balance",
          "alt-enter": "fullscreen",
          "alt-shift-enter": "native-fullscreen",
          "alt-shift-space": "float",
          "alt-shift-c": "close",
          "alt-1": "focus-screen 1",
          "alt-2": "focus-screen 2",
          "alt-3": "focus-screen 3",
          "alt-shift-1": "move-to-screen 1",
          "alt-shift-2": "move-to-screen 2",
          "alt-shift-3": "move-to-screen 3",
          "alt-tab": "focus-screen next",
          "alt-shift-tab": "focus-screen prev",
          "alt-t": "exec open -a kitty",
          "alt-shift-r": "reload",
          "cmd-h": "nop",
          "cmd-alt-h": "nop",
          "alt-r": "mode resize",
          "alt-shift-semicolon": "retile",
          "cmd-alt-ctrl-shift-t": "mode tess",
          "cmd-alt-ctrl-shift-g": "pick",
          "alt-space": "pick",
          "alt-shift-backspace": "clear-screen",
          "cmd-alt-ctrl-shift-r": "jump"
        },
        "tess": {
          "h": "focus left",
          "j": "focus down",
          "k": "focus up",
          "l": "focus right",
          "shift-h": "move left",
          "shift-j": "move down",
          "shift-k": "move up",
          "shift-l": "move right",
          "1": "focus-screen 1",
          "2": "focus-screen 2",
          "3": "focus-screen 3",
          "tab": "focus-screen next",
          "shift-tab": "focus-screen prev",
          "alt-space": "pick",
          "shift-1": "move-to-screen 1",
          "shift-2": "move-to-screen 2",
          "shift-3": "move-to-screen 3",
          "minus": "resize width -50",
          "equal": "resize width +50",
          "b": "balance",
          "f": "fullscreen",
          "space": "float",
          "a": "accordion",
          "v": "flip",
          "shift-c": "close",
          "t": "exec open -a kitty",
          "x": "close-replace",
          "u": "undo",
          "shift-u": "redo",
          "g": "jump",
          "cmd-alt-ctrl-shift-r": "jump",
          "backspace": "clear-screen",
          "cmd-alt-ctrl-shift-g": "pick",
          "w": "rescue",
          "s": "retile",
          "r": "mode resize",
          "esc": "mode main",
          "enter": "mode main",
          "cmd-alt-ctrl-shift-t": "mode main"
        },
        "resize": {
          "h": "resize width -50",
          "l": "resize width +50",
          "j": "resize height +50",
          "k": "resize height -50",
          "esc": "mode back",
          "enter": "mode back",
          "cmd-alt-ctrl-shift-t": "mode back"
        }
      }
    }
    """#

    public static let defaultRaw: Raw = {
        do { return try decodeRaw(Data(defaultJSON.utf8)) } catch { fatalError("built-in config: \(error)") }
    }()

    public static let defaults: Config = {
        do { return try build(defaultRaw) } catch { fatalError("built-in config: \(error)") }
    }()
}
