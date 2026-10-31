import AppKit
import Layout

/// What a pick opens: tabs, links, files, apps and downloads.
extension Tiler {
  /// The next window of `bundle` goes to the spot picked, if any.
  func placeNext(of bundle: String, _ choice: Picker.Choice) {
    if case .place(let spot) = choice {
      pending = (bundle, spot, Date().addingTimeInterval(10))
    }
  }


  func openTab(_ t: Picker.Tab, _ choice: Picker.Choice) {
    Browsers.select(t) { [weak self] in
      guard let self,
        let app = NSRunningApplication.runningApplications(
          withBundleIdentifier: t.bundleID
        ).first
      else { return }
      // The browser raises the tab's window; once it has, that
      // window is the pick.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        self.workers[app.processIdentifier]?.focusedWindow { id in
          if let id { self.use(id, choice) }
        }
      }
    }
  }


  func openURL(
    _ url: URL, in browser: String, _ choice: Picker.Choice
  ) {
    guard
      let app = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: browser)
    else { return }
    placeNext(of: browser, choice)
    NSWorkspace.shared.open(
      [url], withApplicationAt: app,
      configuration: NSWorkspace.OpenConfiguration())
    // A running browser opens a tab in its front window: place that
    // window. Unless a new window opened and took the place
    // already: placing it again would swap it back out. ponytail: a
    // new window slower than 0.6 s loses the race; wait for a
    // window event if that bites.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
      [weak self] in
      guard let self else { return }
      if case .place = choice, self.pending?.bundle != browser {
        return
      }
      guard
        let pid = NSRunningApplication.runningApplications(
          withBundleIdentifier: browser
        ).first?.processIdentifier
      else { return }
      self.workers[pid]?.focusedWindow { id in
        guard let id,
          self.world.contains(id) || self.infos[id] != nil
        else { return }
        self.pending = nil
        self.use(id, choice)
      }
    }
  }


  func runSystem(_ event: String) {
    switch event {
    case "sleep":
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
      p.arguments = ["sleepnow"]
      try? p.run()
    case "lock":
      // ponytail: login.framework's private SACLockScreenImmediate;
      // if Apple drops it, send ctrl-cmd-Q through System Events
      // instead.
      if let h = dlopen(
        "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login",
        RTLD_LAZY),
        let f = dlsym(h, "SACLockScreenImmediate")
      {
        _ = unsafeBitCast(f, to: (@convention(c) () -> Int32).self)()
      }
    default:
      // loginwindow shows its own dialog before logging out,
      // restarting or shutting down.
      Browsers.osascript(
        "tell application \"loginwindow\" to «event aevt\(event)»"
      ) { _ in }
    }
  }


  func downloadPDF(
    _ url: URL, named name: String, title: String,
    _ choice: Picker.Choice
  ) {
    let notice = overlay.beginDownload(
      title, on: lookedAtFrame)
    let dest = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Downloads/\(name)")
    URLSession.shared.downloadTask(with: url) {
      [weak self] tmp, _, _ in
      let ok =
        tmp.map {
          (try? FileManager.default.moveItem(at: $0, to: dest))
            != nil
            || FileManager.default.fileExists(atPath: dest.path)
        } ?? false
      DispatchQueue.main.async {
        guard let self else { return }
        let status =
          ok
          ? (self.openFile(dest.path, choice)
            ? L("Opening") : L("Could not open"))
          : L("Download failed")
        self.overlay.finishDownload(notice, status: status)
      }
    }.resume()
  }


  func getBook(
    _ md5: String, title: String, _ choice: Picker.Choice
  ) {
    let notice = overlay.beginDownload(
      title, on: lookedAtFrame)
    Proc.run(
      "/bin/sh", ["-c", "folio get \"$1\"", "sh", md5],
      env: Proc.env, timeout: 600, log: "folio"
    ) { [weak self] out in
      guard let self else { return }
      let path =
        out?.split(separator: "\n").last.map(String.init) ?? ""
      guard FileManager.default.fileExists(atPath: path) else {
        self.overlay.finishDownload(
          notice, status: L("Download failed"))
        return
      }
      self.overlay.finishDownload(
        notice,
        status: self.openFile(path, choice)
          ? L("Opening") : L("Could not open"))
    }
  }


  func openMatch(
    _ path: String, line: Int, _ choice: Picker.Choice
  ) {
    placeNext(of: "com.microsoft.VSCode", choice)
    let code = ["/usr/local/bin/code", "/opt/homebrew/bin/code"]
      .first { FileManager.default.isExecutableFile(atPath: $0) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: code ?? "/usr/bin/open")
    p.arguments =
      code != nil
      ? ["-g", "\(path):\(line)"]
      : ["-a", "Visual Studio Code", path]
    try? p.run()
  }


  func openPath(
    _ path: String, with name: String, _ choice: Picker.Choice
  ) {
    guard
      let app = apps().first(where: {
        $0.name.caseInsensitiveCompare(name) == .orderedSame
      })
    else {
      toast(L("no app named \(name)"))
      return
    }
    if let b = app.bundleID { placeNext(of: b, choice) }
    NSWorkspace.shared.open(
      [URL(fileURLWithPath: path)], withApplicationAt: app.url,
      configuration: NSWorkspace.OpenConfiguration())
  }


  func openBundle(_ url: URL, _ choice: Picker.Choice) {
    let running = NSWorkspace.shared.runningApplications.first {
      $0.bundleURL == url
    }
    let windows = infos.values.filter {
      $0.pid == running?.processIdentifier && $0.standard
    }.map(\.id)
    if let id = world.pick(windows) {
      use(id, choice)
      return
    }
    if let b = Bundle(url: url)?.bundleIdentifier {
      placeNext(of: b, choice)
    }
    NSWorkspace.shared.openApplication(
      at: url, configuration: NSWorkspace.OpenConfiguration())
  }
}
