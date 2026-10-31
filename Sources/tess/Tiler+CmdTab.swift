import AppKit
import Layout

/// cmd-tab over windows rather than apps: most recently used first,
/// each with its letter.
extension Tiler {
  func onCmdTab(_ key: CmdTab.Key) {
    switch key {
    case .open(let back):
      guard !paused, !starting else { return }
      if picker.isOpen {
        picker.close()
        pickerClosed(cancelled: true)
      }
      let ids = recentWindows
      let apps = windowlessApps(
        besides: Set(ids.compactMap { infos[$0]?.pid }))
      let targets =
        ids.map(Switcher.Target.window)
        + apps.map { .app($0.processIdentifier) }
      guard !targets.isEmpty else { return }
      switcherLetters = stableLabels(
        switcherLetters, windows: targets, alphabet: labelAlphabet)
      let letters = switcherLetters
      let memory = Usage.memory(
        Set(
          ids.compactMap { infos[$0]?.pid }
            + apps.map(\.processIdentifier)))
      // The screen if there are several, the app's memory and how
      // long it has been open.
      func detail(_ app: NSRunningApplication?, screen: Int?)
        -> String
      {
        var d: [String] = []
        if world.monitors.count > 1, let screen {
          d.append(L("Screen \(screen + 1)"))
        }
        if let pid = app?.processIdentifier, let bytes = memory[pid],
          bytes > 0
        {
          d.append(
            ByteCountFormatter.string(
              fromByteCount: Int64(bytes), countStyle: .memory))
        }
        if let launched = app?.launchDate {
          d.append(L("open \(Self.age(launched))"))
        }
        return d.joined(separator: " · ")
      }
      let cards =
        ids.map { id in
          let worker = infos[id].flatMap { workers[$0.pid] }
          let app = worker?.app.localizedName ?? ""
          let m =
            world.locate(id)?.m
            ?? infos[id].flatMap { world.monitorIndex(for: $0.frame) }
          return Switcher.Card(
            target: .window(id),
            icon: worker?.icon ?? worker?.app.icon, app: app,
            title: shortTitle(infos[id]?.title ?? "", app: app),
            detail: detail(worker?.app, screen: m),
            label: letters[.window(id)])
        }
        + apps.map { app in
          Switcher.Card(
            target: .app(app.processIdentifier),
            icon: workers[app.processIdentifier]?.icon ?? app.icon,
            app: app.localizedName ?? "",
            title: app.isHidden
              ? L("Hidden") : L("No window on screen"),
            detail: detail(app, screen: nil),
            label: letters[.app(app.processIdentifier)])
        }
      // The one before what is in front, as macOS's goes to the app
      // before; the first when what is in front is not one of these.
      let front = NSWorkspace.shared.frontmostApplication?
        .processIdentifier
      let inFront: Bool
      switch targets[0] {
      case .window(let id): inFront = infos[id]?.pid == front
      case .app(let pid): inFront = pid == front
      }
      switcher.open(
        cards,
        selected: back
          ? cards.count - 1 : inFront ? min(1, cards.count - 1) : 0,
        strips: world.strips(inner: config.inner, outer: config.outer)
          .filter { !$0.lanes.isEmpty }, on: lookedAtFrame)
      askShortTitles(ids)
    case .step(let back):
      switcher.step(back ? -1 : 1)
    case .letter(let code):
      // Letters only: "down" or "f1" must not go to the card labeled
      // d or f.
      guard
        let c = Hotkeys.codes.first(where: {
          $0.value == UInt32(code) && $0.key.count == 1
        })?.key.first,
        let card = switcher.cards.first(where: { $0.label == c })
      else { return }
      switcher.close()
      go(card.target)
    case .option(let down): holdOption(down)
    case .typed:
      optionHold?.cancel()
      optionHold = nil
    case .cancel:
      switcher.close()
    case .release:
      guard let pick = switcher.pick else { return }
      switcher.close()
      go(pick)
    }
  }

  /// What a card says under the app's name: Jev's pick of the title's
  /// parts once it has answered, else the parts as they are.
  func shortTitle(_ title: String, app: String) -> String {
    shortTitles[title]
      ?? titleParts(title, app: app).joined(separator: " · ")
  }

  /// Asks Jev about the titles of `ids` it has not been asked about,
  /// in one request; the cards change if they are still up when it
  /// answers, and the next cmd-tab has them.
  func askShortTitles(_ ids: [WindowID]) {
    guard config.jev else { return }
    var asked = Set<String>()
    let items = ids.compactMap {
      id -> (app: String, title: String, parts: [String])? in
      guard let title = infos[id]?.title, shortTitles[title] == nil,
        asked.insert(title).inserted
      else { return nil }
      let app = appName(id)
      let parts = titleParts(title, app: app)
      return parts.count > 1 ? (app, title, parts) : nil
    }
    guard !items.isEmpty else { return }
    Jev.titleParts(items) { [weak self] picks in
      guard let self else { return }
      // ponytail: one entry per title ever seen, dropped at 500;
      // titles that change every second (counters, spinners) would
      // want an expiry instead.
      if self.shortTitles.count > 500 { self.shortTitles = [:] }
      self.shortTitles.merge(picks) { $1 }
      self.switcher.retitle { t in
        guard case .window(let id) = t else { return nil }
        return self.infos[id].flatMap { self.shortTitles[$0.title] }
      }
    }
  }

  /// How long ago, at a glance: 12m, 3h, 2d.
  nonisolated static func age(_ since: Date) -> String {
    let m = max(0, Int(-since.timeIntervalSinceNow / 60))
    return m < 60 ? "\(m)m" : m < 1440 ? "\(m / 60)h" : "\(m / 1440)d"
  }

  /// A window gets focus; an app comes forward as its Dock icon would
  /// bring it: shown if it was hidden, and most apps then open a
  /// window.
  func go(_ target: Switcher.Target) {
    switch target {
    case .window(let id):
      use(id, .jump)
    case .app(let pid):
      NSRunningApplication(processIdentifier: pid).map(reopen)
    }
  }

  /// What clicking an app's Dock icon does: it comes forward, shown
  /// if it was hidden, and most apps bring back a minimized window or
  /// open a closed one.
  func reopen(_ app: NSRunningApplication) {
    if let url = app.bundleURL {
      NSWorkspace.shared.openApplication(
        at: url, configuration: NSWorkspace.OpenConfiguration())
    } else {
      app.activate()
    }
  }

  /// Running apps with none of their windows among `pids`' (none
  /// open, hidden, minimized, on another Space), the most recently in
  /// front first.
  func windowlessApps(besides pids: Set<pid_t>)
    -> [NSRunningApplication]
  {
    let apps = NSWorkspace.shared.runningApplications.filter {
      $0.activationPolicy == .regular && !$0.isTerminated
        && $0.processIdentifier != getpid()
        && !pids.contains($0.processIdentifier)
    }
    let recent = recentApps.compactMap { pid in
      apps.first { $0.processIdentifier == pid }
    }
    return recent
      + apps.filter { !recentApps.contains($0.processIdentifier) }
  }

  /// Every window tess knows, most recently focused first, then the
  /// rest in screen order.
  var recentWindows: [WindowID] {
    let all = labeledWindows
    return world.mru.filter(all.contains)
      + all.filter { !world.mru.contains($0) }
  }
}
