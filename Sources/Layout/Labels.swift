/// How keys and commands read in the UI (the mode overlay, the menu).

extension KeySpec {
  /// macOS notation: modifiers in Apple's order (⌃⌥⇧⌘), all four as ✦
  /// (Hyper).
  public var symbol: String {
    let mods =
      mods.count == Mod.allCases.count
      ? "✦"
      : [(Mod.ctrl, "⌃"), (.alt, "⌥"), (.shift, "⇧"), (.cmd, "⌘")]
        .filter { mods.contains($0.0) }.map(\.1).joined()
    return mods + (Self.symbols[key] ?? key.uppercased())
  }

  static let symbols: [String: String] = [
    "backspace": "⌫", "esc": "⎋", "enter": "↩", "tab": "⇥",
    "space": "Space",
    "left": "←", "down": "↓", "up": "↑", "right": "→",
    "minus": "-", "equal": "=", "slash": "/", "backslash": "\\",
    "semicolon": ";", "quote": "'",
    "backtick": "`", "comma": ",", "period": ".",
    "leftSquareBracket": "[", "rightSquareBracket": "]"
  ]
}

extension Command {
  public enum Group: Int, CaseIterable, Sendable {
    case focus, move, layout, more

    public var title: String {
      switch self {
      case .focus: L("Focus")
      case .move: L("Move")
      case .layout: L("Layout")
      case .more: L("More")
      }
    }
  }

  /// Plain words for the overlay and menus; nil for what is not worth
  /// showing.
  public var label: String? {
    switch self {
    case .focus(.left): L("Focus left")
    case .focus(.right): L("Focus right")
    case .focus(.up): L("Focus up")
    case .focus(.down): L("Focus down")
    case .move(.left): L("Move left")
    case .move(.right): L("Move right")
    case .move(.up): L("Move up")
    case .move(.down): L("Move down")
    case .resize(let a, let px):
      a == .width
        ? (px < 0 ? L("Narrower") : L("Wider"))
        : (px < 0 ? L("Shorter") : L("Taller"))
    case .grow(let px): px < 0 ? L("Smaller") : L("Bigger")
    case .balance: L("Balance")
    case .flip: L("Columns ↔ rows")
    case .accordion: L("Accordion")
    case .arrange(.halves): L("Halves")
    case .arrange(.columns): L("Columns")
    case .arrange(.rows): L("Rows")
    case .arrange(.grid): L("Grid")
    case .fullscreen: L("Fullscreen")
    case .float: L("Float")
    case .close: L("Close window")
    case .focusMonitor(let n): L("Screen \(n)")
    case .cycleMonitor(let s):
      s > 0 ? L("Next screen") : L("Previous screen")
    case .cycleWindow(let s):
      s > 0 ? L("Next window") : L("Previous window")
    case .volume(.level(let n)): L("Volume \(n)%")
    case .volume(.step(let n)): n >= 0 ? L("Louder") : L("Quieter")
    case .volume(.mute): L("Mute")
    case .volume(.unmute): L("Unmute")
    case .wifi(let on):
      on.map { $0 ? L("Wi-Fi on") : L("Wi-Fi off") }
        ?? L("Wi-Fi on or off")
    case .caffeine(let m):
      m == 0
        ? L("Let the Mac sleep")
        : m.map { L("Keep awake for \($0) min") } ?? L("Keep awake")
    case .speedtest: L("Speed test")
    case .moveToMonitor(let n): L("Move to screen \(n)")
    case .exec(let line):
      line.hasPrefix("open -a ")
        ? L("Open \(line.dropFirst(8))") : L("Run \(line)")
    case .reload: L("Reload config")
    case .terminal: L("New terminal")
    case .mode(let m):
      m == "main" || m == "back"
        ? L("Back") : L("\(Command.modeName(m)) mode")
    case .retile: L("Re-tile")
    case .rescue: L("Rescue windows")
    case .pause: L("Pause")
    case .pick: L("Picker")
    case .closeReplace: L("Close, pick a replacement")
    case .clearMonitor: L("Clear this screen")
    case .settings: L("Settings")
    case .tutorial: L("Getting Started")
    case .jump: L("Jump to a window")
    case .click: L("Click by label")
    case .showAll: L("Show all apps")
    case .undo: L("Undo")
    case .redo: L("Redo")
    case .zen: "Zen"
    case .zenBreak: L("Break")
    case .focusWindow: L("Go to a window")
    case .swapWith: L("Swap windows")
    case .focusTab: L("Go to a tab")
    case .tree, .nop, .debugMap, .state, .clickKey: nil
    }
  }

  /// A mode's name in the menu bar and on its sheet: tess's own in
  /// words, one from the config as it is written there.
  public static func modeName(_ mode: String) -> String {
    switch mode {
    case "main": L("Main")
    case "resize": L("Resize")
    case "jump": L("Jump")
    case "tess": "tess"
    default: mode.prefix(1).uppercased() + mode.dropFirst()
    }
  }

  public var group: Group {
    switch self {
    case .focus, .focusMonitor, .cycleMonitor, .cycleWindow, .jump:
      .focus
    case .move, .moveToMonitor, .clearMonitor: .move
    case .resize, .grow, .balance, .flip, .accordion, .arrange,
      .fullscreen, .float, .showAll:
      .layout
    default: .more
    }
  }

  /// A binding's label: its first command that says something
  /// ("retile; mode main" is "Re-tile").
  public static func label(of commands: [Command]) -> String? {
    commands.first {
      if case .mode = $0 { return commands.count == 1 };
      return $0.label != nil
    }?.label
  }
}

/// Labels that stay with their windows: windows keep their letter
/// while they live (and it is still in the alphabet), and new windows
/// take the first free letters, in `windows` order. Past the
/// alphabet, none.
public func stableLabels<K: Hashable>(
  _ current: [K: Character], windows: [K], alphabet: String
) -> [K: Character] {
  let alive = Set(windows)
  var out = current.filter {
    alive.contains($0.key) && alphabet.contains($0.value)
  }
  var free = alphabet.filter { c in !out.values.contains(c) }
  for id in windows where out[id] == nil {
    guard !free.isEmpty else { break }
    out[id] = free.removeFirst()
  }
  return out
}
