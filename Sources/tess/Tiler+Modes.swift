import AppKit
import Layout

/// Modes, what they bind, and the config they come from.
extension Tiler {
  /// A one-shot mode (config one_shot) that is not locked: its next
  /// command is its last.
  var oneShotNow: Bool {
    mode != "main" && config.oneShot.contains(mode) && !locked
  }

  /// Where `mode back` and the end of jump mode go from the current
  /// mode: main from a one-shot mode, since what left it was its
  /// command.
  var returnMode: String { oneShotNow ? "main" : mode }

  /// The current mode's keys, without those for screens that are not
  /// attached.
  var modeBindings: [KeySpec: [Command]] {
    forScreens(config.modes[mode] ?? [:], world.monitors.count)
  }

  /// `back` is the mode the current one was entered from (resize
  /// returns to a locked tess mode).
  func setMode(_ requested: String) {
    let m = requested == "back" ? modeBefore : requested
    guard config.modes[m] != nil else { return }
    if m != mode {
      if requested != "back" {
        modeBefore = jumping ? jumpReturn : returnMode
      }
      Events.record("mode", ["mode": m])
    }
    mode = m
    refreshDecorations()
    registerMode()
    refreshTabs()
    if m == "main" {
      overlay.hideMode()
    } else {
      overlay.showMode(
        m, modeBindings, on: modeScreens, letters: labelsAreKeys)
    }
    onChange()
  }


  func registerMode() {
    // The picker has the keyboard; closing it registers the mode
    // again.
    guard !paused, !picking else { return }
    let failed = hotkeys.register(
      mode == "tess"
        ? modeBindings.merging(tessLetterKeys) { binding, _ in binding
        } : modeBindings)
    if !failed.isEmpty {
      Log.write("could not register: \(failed)")
      toast(L("could not register \(failed.joined(separator: ", "))"))
    }
  }


  /// The config's language, for what shows before `start` loads the
  /// rest of it.
  nonisolated static func applyLanguage() {
    let file = try? Data(contentsOf: configURL)
    Strings.language =
      ((try? Config.load(file)) ?? Config.defaults).language
  }


  func loadConfig(announce: Bool) {
    let url = Self.configURL
    do {
      config = try Config.load(
        FileManager.default.fileExists(atPath: url.path)
          ? Data(contentsOf: url) : nil)
      configError = nil
      // In the file it is a choice for every screen, so changing it
      // there changes them.
      if world.ribbons != config.ribbon {
        world.monitors.indices.forEach {
          world.setRibbon($0, config.ribbon)
        }
      }
      world.ribbons = config.ribbon
      Strings.language = config.language
      Panels.accent =
        config.borderColor.map {
          NSColor(srgbRed: $0[0], green: $0[1], blue: $0[2], alpha: 1)
        }
        ?? .controlAccentColor
      Panels.inactiveBorder =
        config.inactiveBorderColor.map {
          NSColor(srgbRed: $0[0], green: $0[1], blue: $0[2], alpha: 1)
        }
        ?? Panels.label(0.22)
      Panels.selection =
        config.selectionColor.map {
          NSColor(srgbRed: $0[0], green: $0[1], blue: $0[2], alpha: 1)
        }
        ?? .systemOrange
      drawn = nil  // redrawn in the new color
      Events.record("config", ["ok": true])
      if announce { toast(L("config reloaded")) }
    } catch {
      configError = "\(error)"
      Log.write("config: \(error)")
      Events.record("config", ["ok": false, "error": "\(error)"])
      toast("\(error)")
    }
    for (pid, w) in workers
    where config.ignore.contains(w.app.bundleIdentifier ?? "") {
      untrack(pid)
    }
    mode = "main"
    overlay.hideMode()
    registerMode()
    if announce { sweep(all: true) }
    onChange()
  }


  func toast(_ s: String, seconds: Double = 1.5) {
    overlay.toast(s, on: lookedAtFrame, seconds: seconds)
  }
}
