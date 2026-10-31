import AppKit
import Layout

/// A newer tess: noticed once a day, shown in the menu bar, and one
/// click away for whoever got it from Homebrew, the one copy tess can
/// replace by itself. Anything else, a build from source above all,
/// is shown the release instead.
extension Tiler {
  static let latestRelease = URL(
    string:
      "https://api.github.com/repos/jonaprieto/tess/releases/latest")!

  static let releasePage = URL(
    string: "https://github.com/jonaprieto/tess/releases/latest")!

  /// Homebrew's prefix if `executable` is in its Cellar, however it
  /// was reached.
  nonisolated static func homebrew(_ executable: String?) -> String? {
    guard let executable else { return nil }
    let path = URL(fileURLWithPath: executable)
      .resolvingSymlinksInPath().path
    return path.range(of: "/Cellar/tess/").map {
      String(path[..<$0.lowerBound])
    }
  }

  /// From start on. The Mac may be offline at login or asleep at any
  /// set hour, so this looks every hour and asks GitHub only when a
  /// day has gone by since it last answered.
  func watchForUpdates() {
    if UserDefaults.standard.string(forKey: "updatedTo") == version {
      UserDefaults.standard.removeObject(forKey: "updatedTo")
      toast(L("tess updated to \(version)"), seconds: 4)
    }
    checkForUpdate()
    let timer = Timer.scheduledTimer(
      withTimeInterval: 3600, repeats: true
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkForUpdate() }
    }
    timer.tolerance = 300
  }

  func checkForUpdate() {
    guard config.updateCheck,
      Date().timeIntervalSince(updateChecked) > 86_400
    else { return }
    askLatest { [weak self] latest in
      guard let self, let latest else { return }
      self.updateChecked = Date()
      self.heard(latest)
    }
  }

  /// The latest release's version on the main thread, nil if GitHub
  /// could not be asked.
  func askLatest(
    _ done: @escaping @MainActor @Sendable (String?) -> Void
  ) {
    URLSession.shared.dataTask(
      with: URLRequest(url: Self.latestRelease, timeoutInterval: 15)
    ) { data, _, _ in
      let latest = data.flatMap {
        Parse.release(String(decoding: $0, as: UTF8.self))
      }
      DispatchQueue.main.async { done(latest) }
    }.resume()
  }

  /// What GitHub answered. A newer version shows in the menu bar, and
  /// says so once.
  func heard(_ latest: String, running: String = version) {
    setUpdate(Parse.isNewer(latest, than: running) ? latest : nil)
    guard let update,
      UserDefaults.standard.string(forKey: "announcedUpdate")
        != update
    else { return }
    UserDefaults.standard.set(update, forKey: "announcedUpdate")
    toast(
      L("tess \(update) is out: update from the menu bar"), seconds: 6
    )
  }

  private func setUpdate(_ new: String?) {
    guard update != new else { return }
    update = new
    onChange()
  }

  /// `tess update`, or the menu: asks now, as a day-old answer may be
  /// out of date.
  func runUpdate() {
    guard !updating else {
      return toast(L("tess is already updating"))
    }
    askLatest { [weak self] latest in
      guard let self else { return }
      guard let latest else {
        return self.toast(L("could not reach GitHub"))
      }
      guard Parse.isNewer(latest, than: version) else {
        self.setUpdate(nil)
        return self.toast(L("tess \(version) is up to date"))
      }
      self.setUpdate(latest)
      self.install(latest)
    }
  }

  /// `brew upgrade`, then launchd starts the new binary. Going by the
  /// version installed after it, not by what brew says: a release
  /// shows up on GitHub before it reaches the tap. Whatever fails,
  /// the running tess carries on.
  func install(
    _ new: String,
    homebrew: String? = Tiler.homebrew(Bundle.main.executablePath)
  ) {
    guard let homebrew else {
      NSWorkspace.shared.open(Self.releasePage)
      return
    }
    updating = true
    let panel = overlay.beginDownload(
      "tess \(new)", on: lookedAtFrame)
    let brew = homebrew + "/bin/brew"
    var env = Proc.env
    // the step before it just did
    env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
    Proc.run(
      brew, ["update", "--quiet"], env: Proc.env, timeout: 120,
      log: "brew update"
    ) { [weak self] _ in
      Proc.run(
        brew, ["upgrade", "jonaprieto/tap/tess"], env: env,
        timeout: 300, log: "brew upgrade"
      ) { _ in
        Proc.run(
          homebrew + "/opt/tess/bin/tess", ["--version"], timeout: 10,
          log: "new tess"
        ) { out in
          guard let self else { return }
          self.updating = false
          guard
            out?.trimmingCharacters(in: .whitespacesAndNewlines)
              == "tess \(new)"
          else {
            return self.overlay.finishDownload(
              panel,
              status: out == nil
                ? L("Update failed")
                : L("Homebrew does not have \(new) yet"))
          }
          UserDefaults.standard.set(new, forKey: "updatedTo")
          if !self.restart() {
            self.overlay.finishDownload(
              panel, status: L("Restart tess to finish"))
          }
        }
      }
    }
  }
}
