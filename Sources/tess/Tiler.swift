import AppKit
import Layout

/// Main thread. Owns the model, turns AX snapshots into model
/// changes, runs commands, and writes frames back through the app
/// workers.
@MainActor
final class Tiler {
  var world = World()

  var config = Config.defaults

  var configError: String?

  var mode = "main" {
    didSet { if mode == "main" { locked = false } }
  }

  /// A one-shot mode entered again stays on until it is left.
  var locked = false

  var paused = false

  /// Called whenever the mode, pause state or config error changes
  /// (for the menu bar).
  var onChange: () -> Void = {}

  /// Called after every layout pass (for the menu bar minimap).
  var onLayout: () -> Void = {}


  var workers: [pid_t: AppWorker] = [:]

  var infos: [WindowID: WinInfo] = [:]

  /// Last frame written per window and how often, so an app that
  /// refuses a size is not fought forever: three tries per target,
  /// reset once the window matches.
  var writes: [WindowID: (target: CGRect, tries: Int)] = [:]

  /// Windows whose frame in `infos` is the one tess wrote, until
  /// their app reports its own.
  var assumed: Set<WindowID> = []

  /// Windows just written and until when they are waited for: the
  /// window server gets there after the app says so, up to 200 ms
  /// later here, with no event to say it did.
  var landing: [WindowID: Date] = [:]

  var landingCheck = false

  /// Snapshots during the first 2 s only collect; then the layout is
  /// rebuilt from where windows are, so a restart keeps it.
  var starting = true

  /// The window macOS says is focused.
  var osFocused: WindowID?

  /// After tess focuses a window, macOS gets one contrary report
  /// overruled (it likes to focus another window of the app whose
  /// window just closed).
  var intent: (id: WindowID, until: Date, reasserted: Bool)?

  var applyScheduled = false

  var screensWork: DispatchWorkItem?

  /// AX only lists the current Space's windows (a native fullscreen
  /// app is a Space of its own). Windows that drop out of an AX list
  /// but still exist are on another Space: they keep their place and
  /// get no frame writes until they are back.
  var offSpace: Set<WindowID> = []

  /// Space changes counted, and the count when each off-Space window
  /// was last listed: a window unlisted across several Space changes
  /// was closed (kept ordered out by its app).
  var spaceChanges = 0

  var unlistedSince: [WindowID: Int] = [:]

  /// Windows floated by the classifier rather than the user;
  /// reconsidered as they settle.
  var autoFloated: Set<WindowID> = []

  /// Windows whose app refused the frame tess asked for (a minimum
  /// size, usually).
  var refused: Set<WindowID> = []

  /// The size each app's windows were seen to keep, 0 on an axis they
  /// gave way on, so the layout is right on the first write. Learned
  /// from refusals, which take most of a second to notice, and
  /// forgotten by a re-tile, for an app that changed.
  // ponytail: in memory, so each app is hit once per run of tess;
  // keep it in defaults if that bites.
  var minimums: [String: CGSize] = [:]

  /// `minimums` for the windows there are.
  var windowMinimums: [WindowID: CGSize] {
    guard !minimums.isEmpty else { return [:] }
    return infos.compactMapValues {
      bundle($0.pid).flatMap { minimums[$0] }
    }
  }

  /// A window that leaves the AX list right after a Space or screen
  /// change went to another Space or is between screens; otherwise it
  /// was closed (apps often keep closed windows around, ordered out,
  /// so the window server list alone cannot tell).
  var spaceChangedAt = Date.distantPast

  /// Window ids only grow: anything at or below this existed before
  /// tess started. Such a window, or one tess has seen before (back
  /// from another Space, minimized, hidden), is placed where it is
  /// when it shows up; only brand new windows get a new lane.
  var preexisting: WindowID = 0

  var seen: Set<WindowID> = []

  /// From a hotkey there is no terminal: an error becomes a toast.
  lazy var hotkeys = Hotkeys { [weak self] commands in
    guard let self else { return }
    let last = self.oneShotNow, from = self.mode
    let out = self.run(commands, source: "hotkey")
    if out.hasPrefix("error: ") {
      self.toast(String(out.dropFirst(7)))
    }
    // That was the one-shot mode's command, unless it locked the mode
    // or left it.
    if last, self.mode == from, !self.locked { self.setMode("main") }
  }

  lazy var picker: Picker = {
    let p = Picker(defaults: .standard)
    p.onDone = { [weak self] item, choice in
      self?.picked(item, choice)
    }
    p.onCancel = { [weak self] in self?.pickerClosed(cancelled: true)
    }
    p.search = { [weak self] kind, query, done in
      self?.search(kind, query, done)
    }
    return p
  }()

  /// The picker is open (or about to open): no hotkeys, no focus
  /// changes.
  var picking = false
  lazy var doctor = DoctorWindow()
  var returnToTutorial = false
  lazy var tutorial: Tutorial = {
    let tutorial = Tutorial()
    tutorial.onPicker = { [weak self] in
      guard let self else { return }
      self.returnToTutorial = true
      let result = self.run([.pick("")], source: "tutorial")
      if result.hasPrefix("error: ") {
        self.returnToTutorial = false
        self.toast(String(result.dropFirst(7)))
      }
    }
    return tutorial
  }()

  /// The tabs labeled while letters are keys, and their letters;
  /// `tabsAsked` drops answers to an earlier ask.
  var tabList: [TabTarget] = []
  var tabLetters: [Character] = []
  var tabsAsked = 0

  /// The window the mouse is moving and where it would land, until
  /// the button comes up.
  var drag: (id: WindowID, zone: DropZone?)?

  /// The picker was opened by close-replace; cancelling it focuses
  /// what tess picked.
  var closeReplacing = false

  /// An app opened from the picker: its first new window goes to
  /// `spot`.
  var pending: (bundle: String, spot: Spot, until: Date)? {
    didSet {
      guard let bundle = pending?.bundle else { return }
      workers.values.first { $0.app.bundleIdentifier == bundle }?
        .expectWindow()
    }
  }

  /// A window picked while its app was not listing it (closed with
  /// its button, kept by the app): the app's next window goes here,
  /// not where it was. By app, as one may show another window when
  /// asked for that one.
  var placing: (pid: pid_t, spot: Spot, until: Date)?

  /// Windows the picker listed from the window server only, with
  /// their app.
  var unseen: [WindowID: pid_t] = [:]

  var appCache:
    (
      apps: [(
        url: URL, name: String, bundleID: String?, icon: NSImage
      )], at: Date, folders: [Date]
    )?

  let overlay = Overlay()


  nonisolated static let configURL = FileManager.default
    .homeDirectoryForCurrentUser.appendingPathComponent(
      ".config/tess/config.json")


  private static var liveCache: (ids: Set<WindowID>, at: Date)?


  var sweeps = 0


  /// The window that had focus when the picker opened; it gets it
  /// back when nothing is picked.
  var focusBeforePicker: WindowID?

  let decorations = Decorations()

  /// Each window's letter, kept while the window lives (decorations,
  /// jump mode, picker map).
  var labels: [WindowID: Character] = [:]

  var jumpReturn = "main"

  /// Option alone on its way to showing the letters, and jump mode
  /// opened that way, which lasts as long as Option is down.
  var optionHold: DispatchWorkItem?

  var jumpHeld = false

  /// The mode before the current one, for `mode back`.
  var modeBefore = "main"

  var drawn: Decorations.Drawn?

  /// A ribbon's windows are sliding to where it scrolled: nothing
  /// else writes until they are there.
  var gliding = false

  /// A newer version than this one, once GitHub has said so, and when
  /// it last answered.
  var update: String?

  var updateChecked = Date.distantPast

  var updating = false

  /// launchd starts a tess that exited with an error, as after a
  /// hang, and that is the new binary now. False if it was not
  /// launchd that started this one.
  var restart: () -> Bool = {
    if getppid() == 1 { exit(1) }
    return false
  }

  /// Layout changes, oldest first; the last `undone` of them were
  /// undone.
  var history: [Step] = []

  var undone = 0

  /// Zen's timer while it is on, and whether it is in a work block.
  var zen: Pomodoro?

  var zenWorking = false

  var zenTimer: Timer?

  /// The power assertion that keeps the Mac awake, and until when
  /// (nil: until turned off).
  var caffeine: (id: UInt32, until: Date?)?

  var caffeineTimer: Timer?

  /// The Shortcuts the picker lists, by name; read with the app list.
  var shortcuts: [String] = []

  /// A speed test under way, so a second one does not halve the
  /// first.
  var speedtest: Process?

  let veil = Veil()

  let grayscale = Grayscale()

  let switcher = Switcher()

  /// Click mode's labels while it lasts, and what has been typed of
  /// one.
  var clickTargets: [ClickTarget] = []

  var clickTyped = ""

  /// cmd-tab's letters, each window's and app's for as long as it
  /// lives, whatever is visible.
  var switcherLetters: [Switcher.Target: Character] = [:]

  /// Apps by when they last came forward, most recent first, for
  /// cmd-tab's app cards.
  var recentApps: [pid_t] = []

  /// Jev's pick of each window title's parts, by title, for cmd-tab's
  /// cards.
  var shortTitles: [String: String] = [:]

  /// cmd-tab's event tap, from start on.
  var cmdTab: CmdTab?


  var searchProcess: Process?


  nonisolated static let appFolders = [
    "/Applications", "/Applications/Utilities",
    "/System/Applications",
    "/System/Applications/Utilities",
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Applications").path
  ]


  func start(restartedAfterHang: Bool) {
    preexisting = Self.liveWindowIDs().max() ?? 0
    loadConfig(announce: false)
    updateMonitors()
    let ws = NSWorkspace.shared.notificationCenter
    func onApp(
      _ name: Notification.Name,
      _ body:
        @escaping @MainActor @Sendable (NSRunningApplication) -> Void
    ) {
      ws.addObserver(forName: name, object: nil, queue: .main) { n in
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication
        {
          MainActor.assumeIsolated { body(app) }
        }
      }
    }
    onApp(NSWorkspace.didLaunchApplicationNotification) {
      [weak self] app in
      self?.track(app)
      self?.workers[app.processIdentifier]?.expectWindow()
    }
    onApp(NSWorkspace.didTerminateApplicationNotification) {
      [weak self] in self?.untrack($0.processIdentifier)
    }
    for name in [
      NSWorkspace.didActivateApplicationNotification,
      NSWorkspace.didHideApplicationNotification,
      NSWorkspace.didUnhideApplicationNotification
    ] {
      onApp(name) { [weak self] app in
        self?.track(app)
        // Another app in front: click mode's labels are on what was.
        if self?.clickTargets.isEmpty == false { self?.endClick() }
        if name == NSWorkspace.didActivateApplicationNotification {
          self?.recentApps.removeAll { $0 == app.processIdentifier }
          self?.recentApps.insert(app.processIdentifier, at: 0)
          self?.workers[app.processIdentifier]?.activated()
        } else {
          self?.workers[app.processIdentifier]?.scheduleRefresh()
        }
        self?.refreshOverlays()
      }
    }
    ws.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.spaceChangedAt = Date()
        self?.spaceChanges += 1
        Events.record(
          "space",
          [
            "frontmost": NSWorkspace.shared.frontmostApplication?
              .bundleIdentifier ?? ""
          ])
        self?.sweep(all: true)
      }
    }
    ws.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        Events.record("wake")
        self?.screensChanged()
        self?.sweep(all: true)
      }
    }
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.screensChanged() }
    }
    NSWorkspace.shared.runningApplications.forEach(track)
    // A safety net: AX notifications report nearly everything as it
    // happens.
    let sweepTimer = Timer.scheduledTimer(
      withTimeInterval: 5, repeats: true
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.sweep() }
    }
    sweepTimer.tolerance = 1
    // A full picture every ten minutes, between the change events.
    let stateTimer = Timer.scheduledTimer(
      withTimeInterval: 600, repeats: true
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        if let self { Events.record("state", self.stateJSON()) }
      }
    }
    stateTimer.tolerance = 30
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      [weak self] in
      self?.starting = false
      self?.rebuild()
      if let self {
        Events.record(
          "start",
          [
            "version": version,
            "restarted_after_hang": restartedAfterHang,
            "state": self.stateJSON()
          ])
      }
      if restartedAfterHang {
        self?.toast(L("restarted after a hang"))
      }
      // warm the caches for the picker
      if let self { Browsers.history(self.config.history) { _ in } }
      self?.watchForUpdates()
      self?.refreshApps()
      _ = self?.picker
    }
    registerMode()
    cmdTab = CmdTab { [weak self] in self?.onCmdTab($0) }
    // The window cmd-tab would go to, in the drag preview's orange,
    // even under others.
    switcher.onPick = { [weak self] pick in
      guard let self else { return }
      var frame: CGRect?
      if case .window(let id)? = pick {
        frame = self.windowStack.first(where: { $0.id == id })?.frame
      }
      self.overlay.showDrop(frame)
    }
    Log.write("started")
  }


  // MARK: Apps and windows

  func track(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard workers[pid] == nil, !app.isTerminated,
      app.activationPolicy == .regular, pid != getpid(),
      app.bundleIdentifier != "com.apple.loginwindow",
      !config.ignore.contains(app.bundleIdentifier ?? "")
    else { return }
    Events.record(
      "app.open",
      [
        "pid": Int(pid), "bundle": app.bundleIdentifier ?? "",
        "name": app.localizedName ?? ""
      ])
    let worker = AppWorker(
      app,
      onSnapshot: { [weak self] pid, list, focused in
        self?.snapshot(pid, list, focused)
      },
      onDrag: { [weak self] id in self?.dragging(id) })
    workers[pid] = worker
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let icon = Icons.small(app.icon)
      DispatchQueue.main.async {
        [weak self] in self?.workers[pid]?.icon = icon
      }
    }
  }


  func untrack(_ pid: pid_t) {
    // didTerminate fires for every process, helpers and ignored apps
    // included.
    guard let worker = workers.removeValue(forKey: pid) else {
      return
    }
    worker.stop()
    Events.record(
      "app.quit",
      [
        "pid": Int(pid), "bundle": worker.app.bundleIdentifier ?? "",
        "name": worker.app.localizedName ?? ""
      ])
    let hadFocus = world.focused
    for (id, info) in infos where info.pid == pid {
      forget(id, "app quit")
    }
    if let hadFocus, !world.contains(hadFocus) { afterFocusChange() }
    scheduleApply()
  }


  func forget(_ id: WindowID, _ why: String = "gone") {
    if infos[id] != nil {
      Events.record(
        "window.close", describe(id).merging(["why": why]) { $1 })
    }
    infos[id] = nil
    writes[id] = nil
    assumed.remove(id)
    landing[id] = nil
    offSpace.remove(id)
    unlistedSince[id] = nil
    autoFloated.remove(id)
    refused.remove(id)
    world.remove(id)
  }


  /// Every window that exists, on any Space. Every window that
  /// exists, on any Space. About 15 ms with a few hundred windows,
  /// and a Space switch asks once per app: one answer serves a
  /// second.
  static func liveWindowIDs() -> Set<WindowID> {
    if let c = liveCache, Date().timeIntervalSince(c.at) < 1 {
      return c.ids
    }
    let list =
      CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
      as? [[String: Any]] ?? []
    let ids = Set(
      list.compactMap {
        ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
      })
    liveCache = (ids, Date())
    return ids
  }


  /// Windows that were already open when tess started: tiled by where
  /// they are, next to where everything else is going.
  // ponytail: rebuilds the whole layout, so accordion and tess
  // fullscreen are reset; place one window by frame in Layout if that
  // ever bites.
  func adopt(_ found: [WinInfo]) {
    // A ribbon is not where its windows are, so it stays out of this:
    // what lands on one joins its end.
    let ribbons = world.monitors.filter(\.ribbon)
    let onRibbons = Set(ribbons.flatMap(\.windows))
    var flat = world
    for i in flat.monitors.indices {
      flat.monitors[i].fullscreen = nil
    }
    let targets = flat.frames(
      inner: config.inner, outer: config.outer
    ).filter { !onRibbons.contains($0.key) }
      .map { (id: $0.key, frame: $0.value) }
    world.rebuild(
      targets + found.map { (id: $0.id, frame: $0.frame) },
      inner: config.inner, outer: config.outer)
    for was in ribbons {
      guard
        let m = world.monitors.firstIndex(where: { $0.id == was.id })
      else { continue }
      let joined = world.monitors[m].lanes
      world.monitors[m] = was
      world.monitors[m].lanes += joined
    }
  }


  func bundle(_ pid: pid_t) -> String? {
    workers[pid]?.app.bundleIdentifier
  }


  func kind(_ info: WinInfo) -> WinInfo.Kind {
    info.kind(bundleID: bundle(info.pid), config)
  }


  func snapshot(_ pid: pid_t, _ list: [WinInfo], _ focused: WindowID?)
  {
    guard workers[pid] != nil else { return }
    let listed = Set(list.map(\.id))
    let hadFocus = world.focused
    // Only windows that just went missing: known off-Space ones need
    // no new lookup.
    let missing = infos.values.filter {
      $0.pid == pid && !listed.contains($0.id)
        && !offSpace.contains($0.id)
    }.map(\.id)
    if !missing.isEmpty {
      let live = Self.liveWindowIDs()
      let spaceChange = Date().timeIntervalSince(spaceChangedAt) < 1.5
      for id in missing {
        if spaceChange && live.contains(id) {
          if offSpace.insert(id).inserted {
            Events.record("window.away", describe(id))
          }
          unlistedSince[id] = unlistedSince[id] ?? spaceChanges
        } else if !offSpace.contains(id) {
          forget(id, "closed")
        }
      }
    }
    for info in list {
      infos[info.id] = info
      assumed.remove(info.id)
      if offSpace.remove(info.id) != nil {
        Events.record("window.back", describe(info.id))
      }
      unlistedSince[info.id] = nil
    }
    let frontmost =
      NSWorkspace.shared.frontmostApplication?.processIdentifier
      == pid
    if frontmost { osFocused = focused }
    let known = seen
    seen.formUnion(listed)
    guard !starting, !paused else { return }
    var found: [WinInfo] = []
    for info in list {
      // macOS fullscreen takes a window to a Space of its own, out of
      // reach of tess's keys: it gets tess fullscreen on its screen
      // instead.
      if info.nativeFullscreen {
        workers[pid]?.leaveNativeFullscreen(info.id)
        if world.locate(info.id) == nil {
          world.place(
            info.id,
            .monitor(
              world.monitorIndex(for: info.frame)
                ?? world.activeMonitor))
        }
        if let p = world.locate(info.id),
          world.monitors[p.m].fullscreen != info.id
        {
          world.focused = info.id
          world.monitors[p.m].fullscreen = info.id
          Events.record(
            "window.fullscreen",
            describe(info.id).merging([
              "how": "instead of macOS fullscreen"
            ]) { $1 })
        }
        continue
      }
      if let p = placing, p.pid == pid, Date() < p.until,
        !world.contains(info.id), kind(info) != .skip
      {
        placing = nil
        world.place(info.id, p.spot)
        Events.record(
          "window.open",
          describe(info.id).merging(["how": "picked back"]) { $1 })
        continue
      }
      switch kind(info) {
      case .skip:
        if world.contains(info.id) {
          world.remove(info.id)
          Events.record(
            "window.untiled",
            describe(info.id).merging(["why": "minimized or hidden"])
            { $1 })
        }
      case .tile where !world.contains(info.id):
        if info.id <= preexisting || known.contains(info.id) {
          found.append(info)
          Events.record(
            "window.open",
            describe(info.id).merging(["how": "adopted where it was"])
            { $1 })
        } else if let p = pending, p.bundle == bundle(pid),
          Date() < p.until
        {
          // The app picked in the picker: its first window goes where
          // step 2 said.
          pending = nil
          world.place(info.id, p.spot)
          Events.record(
            "window.open",
            describe(info.id).merging([
              "how": "placed from the picker"
            ]) { $1 })
        } else if config.emptyScreens, let m = world.emptyMonitor {
          world.place(info.id, .monitor(m))
          Events.record(
            "window.open",
            describe(info.id).merging(["how": "empty screen \(m + 1)"]
            ) { $1 })
          announce(info.id, on: m)
        } else {
          world.insert(info.id)
          Events.record(
            "window.open",
            describe(info.id).merging(["how": "new column"]) { $1 })
        }
      case .float:
        if !world.contains(info.id) {
          world.floating.insert(info.id)
          autoFloated.insert(info.id)
          Events.record(
            "window.open",
            describe(info.id).merging(["how": "floating"]) { $1 })
        }
      case .tile:
        // Floated only because it looked like a dialog at first (no
        // fullscreen button yet, a slow read): it is a normal window
        // now.
        if autoFloated.remove(info.id) != nil,
          world.floating.contains(info.id)
        {
          world.floating.remove(info.id)
          world.insert(info.id)
        }
      }
    }
    if !found.isEmpty { adopt(found) }
    // A background app opening a window does not take focus.
    if !frontmost, world.focused != hadFocus, let hadFocus,
      world.contains(hadFocus)
    {
      world.focused = hadFocus
    }
    if let hadFocus, !world.contains(hadFocus) {
      // The focused window closed (or was minimized): tess's pick,
      // not macOS's.
      afterFocusChange()
    } else if frontmost, let focused {
      syncFocus(focused)
    }
    scheduleApply()
  }


  /// The mouse is moving tiled window `id`: where letting go puts it
  /// shows, and when the button comes up it goes there. By the shown
  /// zone, not the window's frame: macOS may pull a window let go
  /// across two screens back onto the one holding most of it.
  func dragging(_ id: WindowID) {
    guard !paused, world.locate(id) != nil else { return }
    // The dragged window is not in front of what it is dragged over.
    let front = windowStack.map(\.id).filter { $0 != id }
    let zone = world.dropZone(
      id, at: mousePoint,
      frames: world.frames(inner: config.inner, outer: config.outer),
      front: front)
    // The drop shown as it would come out: the window where it lands,
    // after the others make room, and in a swap the other one where
    // it goes.
    var trial = world
    if let zone { trial.drop(id, zone) }
    let after = trial.frames(inner: config.inner, outer: config.outer)
    var swapped: CGRect?
    if case .swap(let t) = zone { swapped = after[t] }
    overlay.showDrop(
      zone == nil ? nil : after[id], caption: zone.map(caption) ?? "",
      also: swapped)
    let watching = drag != nil
    drag = (id, zone)
    guard !watching else { return }
    // borders and letters stand still under a drag: hidden until the
    // drop
    refreshDecorations()
    func check() {
      guard NSEvent.pressedMouseButtons & 1 == 0 else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
          check()
        }
        return
      }
      overlay.showDrop(nil)
      if let (id, zone) = drag, let zone, world.locate(id) != nil {
        let before = world
        world.drop(id, zone)
        if world != before {
          remember("Drag", windowName(id), from: before)
          Events.record(
            "window.dropped",
            describe(id).merging(["zone": "\(zone)"]) { $1 })
        }
      }
      drag = nil
      // Moved by hand: put back even when its place is one it would
      // not fit before.
      writes[id] = nil
      scheduleApply()
    }
    check()
  }


  /// What a drop does, in words, on its preview.
  func caption(_ zone: DropZone) -> String {
    switch zone {
    case .stay: return L("Back in place")
    case .swap(let t): return L("Swap with \(appName(t))")
    case .screen(let m): return L("Screen \(m + 1)")
    case .lane(let t, let after), .stack(let t, let after):
      // A lane is beside in columns and above or below in rows; a
      // stack the other way.
      var stack = false
      if case .stack = zone { stack = true }
      let rows =
        world.locate(t).map { world.monitors[$0.m].rows } ?? false
      let name = appName(t)
      return stack == rows
        ? (after ? L("Right of \(name)") : L("Left of \(name)"))
        : (after ? L("Below \(name)") : L("Above \(name)"))
    }
  }


  /// macOS moved focus (a click, cmd-tab, a window closing).
  func syncFocus(_ id: WindowID) {
    // Overrule macOS once; a second contrary report is the user's own
    // choice.
    if let it = intent, Date() < it.until, it.id != id,
      world.contains(it.id), !it.reasserted
    {
      intent?.reasserted = true
      workerFocus(it.id)
      return
    }
    guard world.contains(id) else { return }
    if world.focused != id {
      world.focused = id
      Events.record(
        "focus", describe(id).merging(["by": "macos"]) { $1 })
    }
    if world.floating.contains(id), let f = infos[id]?.frame,
      let m = world.monitorIndex(for: f)
    {
      world.activeMonitor = m
    }
  }


  /// The focused window left: give macOS a runloop pass, then focus
  /// tess's choice.
  func afterFocusChange() {
    guard let next = world.focused else { return }
    DispatchQueue.main.async { [weak self] in self?.focus(next) }
  }


  /// Never while the picker is open: another app taking focus would
  /// close it.
  func focus(_ id: WindowID) {
    guard !picking else { return }
    Events.record(
      "focus", describe(id).merging(["by": "tess"]) { $1 })
    intent = (id, Date().addingTimeInterval(0.3), false)
    workerFocus(id)
  }


  func workerFocus(_ id: WindowID) {
    guard let info = infos[id] else { return }
    workers[info.pid]?.focus(id)
  }


  /// The frontmost app every 5 s, every app every 30 s (or `all`,
  /// after a Space change or a wake): each refresh costs the app a
  /// few AX round trips on its main thread.
  func sweep(all: Bool = false) {
    sweeps += 1
    let everything = all || sweeps % 6 == 0
    if let c = appCache, Date().timeIntervalSince(c.at) > 600 {
      refreshApps()
    }
    if everything {
      NSWorkspace.shared.runningApplications.forEach(track)
      if !offSpace.isEmpty {
        let live = Self.liveWindowIDs()
        for id in offSpace
        where !live.contains(id)
          || spaceChanges - (unlistedSince[id] ?? spaceChanges) >= 4
        {
          forget(id, "closed while on another Space")
        }
      }
      // Nothing in the layout without a window behind it.
      for id in world.tiled + Array(world.floating)
      where infos[id] == nil && !offSpace.contains(id) {
        world.remove(id)
      }
      // Writes refused earlier get another three tries, rarely: each
      // makes the app lay itself out again, and most refusals are a
      // minimum size that will not change.
      if all || sweeps % 60 == 0 { writes = [:] }
      scheduleApply()
    }
    let front = NSWorkspace.shared.frontmostApplication?
      .processIdentifier
    for (pid, w) in workers {
      if w.app.isTerminated {
        untrack(pid)
      } else if everything || pid == front {
        w.scheduleRefresh()
      }
    }
    // A window can also change with no event at all, and a border
    // left behind stays there.
    refreshOverlays()
  }


  /// Re-tiles every known window from where it is now.
  func rebuild() {
    let tiles = infos.values.filter { kind($0) == .tile }.sorted {
      $0.id < $1.id
    }
    world.rebuild(
      tiles.map { (id: $0.id, frame: $0.frame) }, inner: config.inner,
      outer: config.outer)
    world.floating = Set(
      infos.values.filter { kind($0) == .float }.map(\.id))
    if let f = osFocused, world.contains(f) { world.focused = f }
    writes = [:]
    minimums = [:]
    apply()
  }
}

extension Array {
  subscript(safe i: Int) -> Element? {
    indices.contains(i) ? self[i] : nil
  }
}
