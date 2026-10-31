import Carbon
import Layout

/// Global hotkeys through Carbon's `RegisterEventHotKey`: no Input
/// Monitoring needed, and a registered key never reaches the focused
/// app.
final class Hotkeys {
  private var refs: [EventHotKeyRef] = []
  private var actions: [UInt32: [Command]] = [:]
  private var eventHandler: EventHandlerRef?
  private let handler: ([Command]) -> Void

  init(handler: @escaping ([Command]) -> Void) {
    self.handler = handler
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, refcon in
        var id = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID),
          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        let me = Unmanaged<Hotkeys>.fromOpaque(refcon!)
          .takeUnretainedValue()
        if let commands = me.actions[id.id] { me.handler(commands) }
        return noErr
      }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(),
      &eventHandler)
  }

  deinit {
    unregisterAll()
    if let eventHandler { RemoveEventHandler(eventHandler) }
  }

  /// Replaces every registered key with `bindings`; returns the keys
  /// that could not be had.
  func register(_ bindings: [KeySpec: [Command]]) -> [String] {
    unregisterAll()
    var bindings = bindings
    let pickerKey = KeySpec(key: "space", mods: [.cmd])
    if bindings[pickerKey] == nil {
      bindings[pickerKey] = [.pick("")]
    }
    var failed: [String] = []
    for (n, (spec, commands)) in bindings.sorted(by: {
      $0.key.description < $1.key.description
    }).enumerated() {
      guard let code = Self.codes[spec.key] else {
        failed.append(spec.description); continue
      }
      var mods = 0
      if spec.mods.contains(.cmd) { mods |= cmdKey }
      if spec.mods.contains(.alt) { mods |= optionKey }
      if spec.mods.contains(.ctrl) { mods |= controlKey }
      if spec.mods.contains(.shift) { mods |= shiftKey }
      var ref: EventHotKeyRef?
      let id = EventHotKeyID(
        signature: OSType(0x7465_7373), id: UInt32(n + 1))  // 'tess'
      if RegisterEventHotKey(
        code, UInt32(mods), id, GetApplicationEventTarget(), 0, &ref)
        == noErr, let ref
      {
        refs.append(ref)
        actions[id.id] = commands
      } else {
        // Spotlight may own Cmd-Space; the picker still has
        // Alt-Space.
        if spec != KeySpec(key: "space", mods: [.cmd])
          || commands != [.pick("")]
        {
          failed.append(spec.description)
        }
      }
    }
    return failed
  }

  func unregisterAll() {
    refs.forEach { UnregisterEventHotKey($0) }
    refs = []
    actions = [:]
  }

  static let codes: [String: UInt32] = {
    var c: [String: Int] = [
      "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C,
      "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
      "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I,
      "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
      "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
      "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
      "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U,
      "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
      "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
      "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2,
      "3": kVK_ANSI_3, "4": kVK_ANSI_4,
      "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
      "8": kVK_ANSI_8, "9": kVK_ANSI_9,
      "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal,
      "period": kVK_ANSI_Period, "comma": kVK_ANSI_Comma,
      "slash": kVK_ANSI_Slash, "backslash": kVK_ANSI_Backslash,
      "quote": kVK_ANSI_Quote,
      "semicolon": kVK_ANSI_Semicolon, "backtick": kVK_ANSI_Grave,
      "leftSquareBracket": kVK_ANSI_LeftBracket,
      "rightSquareBracket": kVK_ANSI_RightBracket,
      "space": kVK_Space, "enter": kVK_Return, "esc": kVK_Escape,
      "backspace": kVK_Delete, "tab": kVK_Tab,
      "left": kVK_LeftArrow, "down": kVK_DownArrow, "up": kVK_UpArrow,
      "right": kVK_RightArrow
    ]
    let f = [
      kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
      kVK_F9, kVK_F10,
      kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17,
      kVK_F18, kVK_F19, kVK_F20
    ]
    for (i, code) in f.enumerated() { c["f\(i + 1)"] = code }
    return c.mapValues(UInt32.init)
  }()
}
