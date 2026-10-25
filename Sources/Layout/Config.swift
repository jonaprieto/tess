import Foundation

/// `~/.config/tess/config.json`. A file replaces the defaults as a whole; start from
/// `tess default-config`.
public struct Config: Equatable, Sendable {
    public var inner: Double = 10
    public var outer: Double = 10
    /// Bundle ids whose windows float.
    public var float: [String] = []
    /// Bundle ids whose windows tile even without a fullscreen button.
    public var tile: [String] = []
    /// Bundle ids tess never touches.
    public var ignore: [String] = []
    /// Mode -> key -> commands. `main` is where tess starts.
    public var modes: [String: [KeySpec: [Command]]] = [:]

    struct Raw: Decodable {
        struct Gaps: Decodable { var inner: Double?, outer: Double? }
        var gaps: Gaps?
        var float: [String]?
        var tile: [String]?
        var ignore: [String]?
        var modes: [String: [String: String]]
    }

    public static func decode(_ data: Data) throws -> Config {
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch let DecodingError.dataCorrupted(ctx) {
            throw ParseError("config is not valid JSON: \(ctx.underlyingError.map { "\($0)" } ?? ctx.debugDescription)")
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw ParseError("config: missing \((ctx.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: "."))")
        } catch let DecodingError.typeMismatch(_, ctx) {
            throw ParseError("config: wrong type at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
        }
        var c = Config()
        c.inner = raw.gaps?.inner ?? 10
        c.outer = raw.gaps?.outer ?? 10
        c.float = raw.float ?? []
        c.tile = raw.tile ?? []
        c.ignore = raw.ignore ?? []
        guard raw.modes["main"] != nil else { throw ParseError("config: modes.main is missing") }
        for (mode, bindings) in raw.modes {
            var parsed: [KeySpec: [Command]] = [:]
            for (key, line) in bindings {
                do {
                    let commands = try Command.parse(line)
                    for case .mode(let m) in commands where raw.modes[m] == nil {
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
      "float": ["com.apple.systempreferences", "com.apple.ActivityMonitor", "com.apple.calculator", "com.apple.finder"],
      "tile": ["com.anthropic.claudefordesktop"],
      "ignore": ["io.github.ender-wang.EdgeMark"],
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
          "alt-1": "focus-monitor 1",
          "alt-2": "focus-monitor 2",
          "alt-3": "focus-monitor 3",
          "alt-shift-1": "move-to-monitor 1",
          "alt-shift-2": "move-to-monitor 2",
          "alt-shift-3": "move-to-monitor 3",
          "alt-tab": "focus-monitor next",
          "alt-shift-tab": "focus-monitor prev",
          "alt-t": "exec open -a kitty",
          "alt-shift-r": "reload",
          "cmd-h": "nop",
          "cmd-alt-h": "nop",
          "alt-r": "mode resize",
          "alt-shift-semicolon": "mode service",
          "cmd-alt-ctrl-shift-t": "mode wm",
          "cmd-alt-ctrl-shift-g": "pick",
          "alt-space": "pick"
        },
        "wm": {
          "h": "focus left",
          "j": "focus down",
          "k": "focus up",
          "l": "focus right",
          "shift-h": "move left",
          "shift-j": "move down",
          "shift-k": "move up",
          "shift-l": "move right",
          "1": "focus-monitor 1",
          "2": "focus-monitor 2",
          "3": "focus-monitor 3",
          "tab": "focus-monitor next",
          "shift-1": "move-to-monitor 1",
          "shift-2": "move-to-monitor 2",
          "shift-3": "move-to-monitor 3",
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
          "cmd-alt-ctrl-shift-g": "pick",
          "w": "rescue",
          "r": "mode resize",
          "s": "mode service",
          "esc": "mode main",
          "enter": "mode main",
          "cmd-alt-ctrl-shift-t": "mode main"
        },
        "resize": {
          "h": "resize width -50",
          "l": "resize width +50",
          "j": "resize height +50",
          "k": "resize height -50",
          "esc": "mode main",
          "enter": "mode main"
        },
        "service": {
          "r": "retile; mode main",
          "w": "rescue; mode main",
          "f": "float; mode main",
          "esc": "mode main"
        }
      }
    }
    """#

    public static let defaults: Config = {
        do { return try decode(Data(defaultJSON.utf8)) } catch { fatalError("built-in config: \(error)") }
    }()
}
