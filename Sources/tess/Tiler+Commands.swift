import AppKit
import Layout

/// Commands from hotkeys, the CLI and the menu.
extension Tiler {
  // MARK: Commands

  // MARK: Commands

  /// Runs commands from a hotkey or the CLI; returns what to print.
  /// `source` says where the commands came from (hotkey, cli, menu,
  /// picker) for the event log.
  func run(_ commands: [Command], source: String = "internal")
    -> String
  {
    let before = world
    let out = commands.map(execute).filter { !$0.isEmpty }.joined(
      separator: "\n")
    if commands != [.state], commands != [.tree], commands != [.nop] {
      var e: [String: Any] = [
        "cmd": commands.map(\.description).joined(separator: "; "),
        "source": source
      ]
      if out.hasPrefix("error: ") {
        e["error"] = String(out.dropFirst(7))
      }
      Events.record("command", e)
    }
    if world != before { Events.record("layout", layoutJSON()) }
    if !commands.contains(.undo), !commands.contains(.redo) {
      remember(
        Command.label(of: commands)
          ?? commands.map(\.description).joined(separator: "; "),
        windowName(before.focused), from: before)
    }
    return out
  }


  /// A resize stops at what a window keeps: without this the layout
  /// would go on taking room from it on paper and handing it to a
  /// neighbor, which would grow underneath.
  func holdMinimums(_ was: World) {
    world.respect(
      windowMinimums, inner: config.inner, outer: config.outer)
    let old = was.frames(inner: config.inner, outer: config.outer)
    if world.frames(inner: config.inner, outer: config.outer)
      .allSatisfy({ old[$0.key]?.isNear($0.value) == true })
    {
      toast(L("no room left"))
    }
  }


  func execute(_ c: Command) -> String {
    if paused,
      ![.pause, .tree, .reload, .tutorial, .update].contains(c)
    {
      return "error: \(L("paused"))"
    }
    Log.write("command: \(c)")
    let before = world.focused
    let beforeMonitor = world.activeMonitor
    var flash = false
    if let error = floatingRefusal(of: c) { return error }
    switch c {
    case .focus(let d): world.focus(d); flash = true
    case .move(let d): world.move(d); flash = true
    case .resize(let a, let px):
      let was = world
      world.resize(a, by: px)
      holdMinimums(was)
    case .grow(let px):
      let was = world
      world.grow(by: px)
      holdMinimums(was)
    case .balance: balanceLanes()
    case .arrange(let a): world.arrange(a)
    case .flip:
      world.flip()
      // Said also when a lone window shows no difference: the next
      // one goes beside or below it.
      toast(
        world.monitors[safe: world.activeMonitor]?.rows == true
          ? L("rows") : L("columns"))
    case .accordion: world.toggleAccordion()
    case .fullscreen: toggleFullscreenTiled()
    case .float:
      if let error = toggleFloatingFocused() { return error }
    case .close:
      guard let id = world.focused ?? osFocused, let info = infos[id]
      else { return "error: \(L("no window focused"))" }
      workers[info.pid]?.close(id)
    case .focusMonitor(let n): world.focusMonitor(n - 1); flash = true
    case .cycleMonitor(let s): world.cycleMonitor(s); flash = true
    case .cycleWindow(let s): world.cycleWindow(s); flash = true
    case .volume(let v): setVolume(v)
    case .wifi(let on): setWifi(on)
    case .caffeine(let minutes): setCaffeine(minutes)
    case .speedtest: runSpeedtest()
    case .update: runUpdate()
    case .ribbon:
      world.toggleRibbon()
      toast(
        world.monitors[safe: world.activeMonitor]?.ribbon == true
          ? L("ribbon on") : L("ribbon off"))
    case .moveToMonitor(let n):
      if let id = world.focused, world.floating.contains(id) {
        moveFloating(id, to: n - 1)
      } else {
        world.moveToMonitor(n - 1)
      }
      flash = true
    case .exec(let line):
      if let error = launch("/bin/sh", ["-c", line]) { return error }
    case .terminal:
      // Opening a folder with a terminal app gives a new window
      // there, as the `cd` verb does.
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      if let error = launch(
        "/usr/bin/open", ["-a", config.terminal, home])
      {
        return error
      }
    case .reload: loadConfig(announce: true)
    case .mode(let m): enterMode(m)
    case .retile: retile()
    case .rescue: toast(L("rescued \(rescue()) windows"))
    case .pause: setPaused(!paused)
    case .tree: return tree()
    case .nop: break
    case .pick(let text): togglePicker(text)
    case .debugMap(let path): return writeDebugMap(path)
    case .settings: openSettings()
    case .tutorial: tutorial.show(config)
    case .jump: startJump()
    case .click: startClick()
    case .clickKey(let k): clickKey(k)
    case .showAll: showAll()
    case .undo: return undo()
    case .redo: return redo()
    case .zen: toggleZen()
    case .zenBreak: takeBreak()
    case .focusWindow(let id):
      guard infos[id] != nil else {
        return "error: \(L("no window \(id)"))"
      }
      use(id, .jump)
    case .focusTab(let n):
      if let error = focusTab(n) { return error }
    case .swapWith(let id):
      if let error = swapFocused(with: id) { return error }
      flash = true
    case .state: return stateText()
    case .clearMonitor:
      world.clearMonitor()
      flash = true
    case .closeReplace:
      if let error = closeAndReplace() { return error }
    }
    if world.focused != before, let f = world.focused { focus(f) }
    if flash { flashFocus() }
    if world.activeMonitor != beforeMonitor { sheetFollowsScreen() }
    scheduleApply()
    return ""
  }


  /// Commands on a tiled window say so when the focused one floats,
  /// instead of doing nothing.
  private func floatingRefusal(of c: Command) -> String? {
    guard let f = world.focused, world.floating.contains(f),
      c == .accordion || c.isMoveOrResize
    else { return nil }
    let key = config.modes["main"]?.first { $0.value == [.float] }?
      .key.symbol
    return "error: "
      + (key.map { L("\(appName(f)) floats; \($0) tiles it") }
        ?? L("\(appName(f)) floats"))
  }


  private func enterMode(_ m: String) {
    // Entering a one-shot mode again keeps it on until esc.
    if m == mode, oneShotNow {
      locked = true
      toast(L("\(Command.modeName(m)) mode locked"))
    }
    setMode(m)
  }


  /// A single cheat sheet follows to the screen being worked on.
  private func sheetFollowsScreen() {
    guard mode != "main", !config.emptyScreens,
      !config.overlayAllScreens,
      let m = world.monitors[safe: world.activeMonitor]
    else { return }
    overlay.showMode(
      mode, modeBindings, on: [m.frame], letters: labelsAreKeys)
  }


  private func balanceLanes() {
    let was = world.frames(inner: config.inner, outer: config.outer)
    world.balance()
    world.respect(
      windowMinimums, inner: config.inner, outer: config.outer)
    if world.frames(inner: config.inner, outer: config.outer) == was {
      toast(L("already even"))
    }
  }


  private func toggleFullscreenTiled() {
    // A floating window joins the tiling to go fullscreen.
    if let f = world.focused, world.floating.contains(f) {
      world.toggleFloating(f)
    }
    world.toggleFullscreen()
    if let f = world.focused, world.locate(f) != nil {
      focus(f)
      let on =
        world.locate(f).map { world.monitors[$0.m].fullscreen == f }
        ?? false
      toast(on ? L("fullscreen") : L("fullscreen off"))
    }
  }


  /// The error, if any, as with the ones below.
  private func toggleFloatingFocused() -> String? {
    guard let id = world.focused ?? osFocused, world.contains(id)
    else {
      return "error: \(L("no tiled or floating window focused"))"
    }
    world.toggleFloating(id)
    let floating = world.floating.contains(id)
    let key = config.modes["main"]?.first { $0.value == [.float] }?
      .key.symbol
    toast(
      floating
        ? key.map { L("Floating · \($0) returns to tiling") }
          ?? L("Floating") : L("Tiled"))
    return nil
  }


  private func launch(_ path: String, _ arguments: [String])
    -> String?
  {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    do {
      try p.run()
      return nil
    } catch { return "error: \(error)" }
  }


  private func retile() {
    sweep(all: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      [weak self] in
      guard let self else { return }
      let before = self.world
      self.rebuild()
      self.remember(L("Re-tile"), "", from: before)
      self.toast(L("re-tiled"))
    }
  }


  private func togglePicker(_ text: String) {
    if picker.isOpen {
      picker.close()
      pickerClosed(cancelled: true)
    } else {
      openPicker(fixed: nil, text: text)
    }
  }


  private func writeDebugMap(_ path: String) -> String {
    let png = Picker.render(
      pickerMap(), size: NSSize(width: 1000, height: 550))
    do { try png?.write(to: URL(fileURLWithPath: path)) } catch {
      return "error: \(error)"
    }
    return path
  }


  private func focusTab(_ n: Int) -> String? {
    guard tabList.indices.contains(n),
      infos[tabList[n].window] != nil
    else { return "error: \(L("no tab \(n)"))" }
    let t = tabList[n]
    workers[t.pid]?.press(t.element)
    use(t.window, .jump)
    return nil
  }


  private func swapFocused(with id: WindowID) -> String? {
    guard let f = world.focused, f != id, world.locate(f) != nil,
      world.locate(id) != nil
    else {
      return
        "error: \(L("swap needs a focused tiled window and another tiled window"))"
    }
    world.swap(f, id)
    world.focused = f
    return nil
  }


  private func stateText() -> String {
    let data =
      (try? JSONSerialization.data(
        withJSONObject: stateJSON(),
        options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }


  private func closeAndReplace() -> String? {
    guard let id = world.focused, let s = world.slot(of: id),
      let info = infos[id]
    else {
      return "error: \(L("no tiled window focused"))"
    }
    beginPicking()
    closeReplacing = true
    world.remove(id)
    workers[info.pid]?.close(id)
    // Let macOS settle on whatever it focuses next, then take the
    // keyboard.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      [weak self] in
      self?.showPicker(fixed: .slot(s.position, alone: s.alone))
    }
    return nil
  }


  /// Outlines the focused window (or the active monitor when it has
  /// none) once the move has landed: by then the window's own report
  /// says where it really is.
  func flashFocus(after delay: Double = 0.18) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      [weak self] in
      guard let self else { return }
      // The focused window's border already says it.
      if self.config.windowLabels != .off, self.world.focused != nil {
        return
      }
      let frame = self.world.focused.flatMap { id in
        self.windowStack.first(where: { $0.id == id })?.frame
      }
      self.overlay.flash(frame ?? self.activeFrame)
    }
  }


  func moveFloating(_ id: WindowID, to m: Int) {
    guard world.monitors.indices.contains(m), let info = infos[id]
    else { return }
    let target = CGRect.centered(
      info.frame.size, in: world.monitors[m].frame)
    workers[info.pid]?.setFrame(id, target)
    infos[id]?.frame = target
    world.activeMonitor = m
  }


  /// Every window showing less than a tenth of itself on any screen
  /// comes back: tiled ones get their frame written again, the rest
  /// are centered on the active monitor.
  func rescue() -> Int {
    var n = 0
    let screens = world.monitors.map(\.frame)
    let parked = world.parked(
      inner: config.inner, outer: config.outer)
    for (id, info) in infos
    where info.standard && !offSpace.contains(id)
      && !parked.contains(id)
    {
      guard info.frame.isLost(on: screens) else { continue }
      n += 1
      if world.locate(id) != nil {
        writes[id] = nil
        infos[id]?.frame = .zero
      } else {
        let target = CGRect.centered(info.frame.size, in: activeFrame)
        workers[info.pid]?.setFrame(id, target)
        infos[id]?.frame = target
      }
    }
    Log.write("rescued \(n)")
    apply()
    return n
  }


  func setPaused(_ p: Bool) {
    paused = p
    CmdTab.enabled.store(!p, ordering: .relaxed)
    if p {
      hotkeys.unregisterAll()
      overlay.hideMode()
    } else {
      mode = "main"
      registerMode()
      rebuild()
    }
    toast(p ? L("paused") : L("resumed"))
    onChange()
  }


  // MARK: Rescue from the menu

  // MARK: Rescue from the menu

  func menuRescue() { toast(L("rescued \(rescue()) windows")) }


  /// For the menu header: mode, windows, screens.
  var summary: String {
    let n = world.tiled.count + world.floating.count
    let screens = world.monitors.count
    return [
      paused ? L("paused") : L("\(Command.modeName(mode)) mode"),
      n == 1 ? L("1 window") : L("\(n) windows"),
      screens == 1 ? L("1 screen") : L("\(screens) screens")
    ].joined(separator: " · ")
  }


  func openSettings() {
    SettingsWindow.shared.show(
      raw: config.raw, on: config.emptyScreens ? leastBusyFrame : nil
    ) { [weak self] raw in
      self?.saveSettings(raw)
    }
  }


  /// Validates and writes what the settings window changed, then
  /// reloads; the error if not.
  func saveSettings(_ raw: Config.Raw) -> String? {
    // Saving now would replace the hand-edited file with these
    // settings.
    if let e = configError {
      return L(
        "config.json has an error, fix it or delete it first: \(e)")
    }
    do {
      _ = try Config.validate(raw)
      try FileManager.default.createDirectory(
        at: Self.configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try Config.file(for: raw).write(
        to: Self.configURL, options: .atomic)
      loadConfig(announce: true)
      return configError
    } catch {
      return "\(error)"
    }
  }

  func menuRetile() { _ = run([.retile], source: "menu") }

  func menuPause() { _ = run([.pause], source: "menu") }

  func menuReload() { _ = run([.reload], source: "menu") }
}
