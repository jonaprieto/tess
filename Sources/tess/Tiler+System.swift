import AppKit
import IOKit.pwr_mgt
import Layout

/// The Mac's own switches, as commands: volume, Wi-Fi and caffeine,
/// and the person's Shortcuts, which the picker lists.
extension Tiler {
  /// Through AppleScript's `set volume`, which needs no permission.
  func setVolume(_ v: Volume) {
    let change =
      switch v {
      case .level(let n):
        "set volume output volume \(n) without output muted"
      case .step(let n):
        "set volume output volume ((output volume of (get volume settings)) + \(n)) without output muted"
      case .mute: "set volume with output muted"
      case .unmute: "set volume without output muted"
      }
    let report =
      "set s to get volume settings\nif output muted of s then return \"muted\"\nreturn (output volume of s) as text"
    var error: NSDictionary?
    let now = NSAppleScript(source: change + "\n" + report)?
      .executeAndReturnError(&error)
    guard error == nil else {
      return toast(L("volume did not change"))
    }
    let level = now?.stringValue
    toast(
      level == "muted"
        ? L("muted")
        : level.map { L("volume \($0)%") } ?? L("volume changed"))
  }

  /// Through `networksetup` on the Wi-Fi device; nil turns it the
  /// other way round.
  func setWifi(_ on: Bool?) {
    let tool = "/usr/sbin/networksetup"
    Proc.run(tool, ["-listallhardwareports"], timeout: 5) {
      [weak self] out in
      guard let self, let device = out.flatMap(Parse.wifiDevice)
      else { return self?.toast(L("no Wi-Fi here")) ?? () }
      @MainActor func set(_ on: Bool) {
        Proc.run(
          tool, ["-setairportpower", device, on ? "on" : "off"],
          timeout: 10, log: "networksetup"
        ) { [weak self] r in
          self?.toast(
            r == nil
              ? L("Wi-Fi did not change")
              : on ? L("Wi-Fi on") : L("Wi-Fi off"))
        }
      }
      if let on { return set(on) }
      Proc.run(tool, ["-getairportpower", device], timeout: 5) {
        out in
        set(!(out.flatMap(Parse.wifiPower) ?? false))
      }
    }
  }

  /// A display-sleep assertion, which keeps the system awake too,
  /// and closing the lid no longer sleeps it, so it can work in a
  /// bag (the screen goes dark then, see `lidChanged`); for
  /// `minutes` or until turned off; `caffeine` alone turns it off
  /// when it is on. Released when tess quits.
  func setCaffeine(_ minutes: Int?) {
    let wasOn = caffeine != nil
    if let c = caffeine { IOPMAssertionRelease(c.id) }
    if wasOn { Self.lidSleep(true) }
    caffeine = nil
    caffeineTimer?.invalidate()
    caffeineTimer = nil
    defer { onChange() }
    if minutes == 0 || (minutes == nil && wasOn) {
      return toast(L("the Mac can sleep"))
    }
    guard let id = Self.awake(screen: !Self.lidClosed)
    else { return toast(L("could not keep the Mac awake")) }
    let until = minutes.map {
      Date().addingTimeInterval(Double($0) * 60)
    }
    caffeine = (id, until)
    Self.lidSleep(false)
    if let until {
      caffeineTimer = Timer.scheduledTimer(
        withTimeInterval: until.timeIntervalSinceNow, repeats: false
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.setCaffeine(0) }
      }
    }
    toast(
      minutes.map { L("awake for \($0) min") }
        ?? L("keeping the Mac awake"))
  }

  /// Caffeine's assertion: the screen and so the system, or the
  /// system alone.
  nonisolated static func awake(screen: Bool) -> IOPMAssertionID? {
    var id: IOPMAssertionID = 0
    return IOPMAssertionCreateWithName(
      (screen
        ? kIOPMAssertionTypePreventUserIdleDisplaySleep
        : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      "tess caffeine" as CFString,
      &id) == kIOReturnSuccess ? id : nil
  }

  /// With caffeine on, a closed lid keeps only the system awake and
  /// turns the screen off, which also darkens the keyboard; opening
  /// it holds the screen again.
  func lidChanged(_ closed: Bool) {
    guard let c = caffeine, let id = Self.awake(screen: !closed)
    else { return }
    IOPMAssertionRelease(c.id)
    caffeine = (id, c.until)
    if closed {
      Proc.run("/usr/bin/pmset", ["displaysleepnow"], timeout: 5) {
        _ in
      }
    }
  }

  nonisolated static var lidClosed: Bool {
    let root = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    defer { IOObjectRelease(root) }
    return IORegistryEntryCreateCFProperty(
      root, "AppleClamshellState" as CFString, nil, 0)?
      .takeRetainedValue() as? Bool == true
  }

  /// Calls `lidChanged` on the root domain's clamshell message, for
  /// as long as tess runs.
  func watchLid() {
    let root = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    defer { IOObjectRelease(root) }
    guard let port = IONotificationPortCreate(kIOMainPortDefault)
    else { return }
    IONotificationPortSetDispatchQueue(port, .main)
    var note: io_object_t = 0
    IOServiceAddInterestNotification(
      port, root, kIOGeneralInterest,
      { me, _, message, arg in
        // kIOPMMessageClamshellStateChange, a macro Swift can't read
        guard message == 0xE003_4100, let me else { return }
        let closed =
          Int(bitPattern: arg) & Int(kClamshellStateBit) != 0
        MainActor.assumeIsolated {
          Unmanaged<Tiler>.fromOpaque(me).takeUnretainedValue()
            .lidChanged(closed)
        }
      }, Unmanaged.passUnretained(self).toOpaque(), &note)
  }

  /// The root domain's clamshell switch, which any local user may
  /// flip, battery or not; low battery and heat still sleep the Mac.
  /// The kernel keeps it past tess, so `serve` turns it back on at
  /// start and exit.
  nonisolated static func lidSleep(_ on: Bool) {
    let root = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    defer { IOObjectRelease(root) }
    var c: io_connect_t = 0
    guard IOServiceOpen(root, mach_task_self_, 0, &c) == KERN_SUCCESS
    else { return }
    defer { IOServiceClose(c) }
    var disable: UInt64 = on ? 0 : 1
    _ = IOConnectCallScalarMethod(
      c, UInt32(kPMSetClamshellSleepState), &disable, 1, nil, nil)
  }

  /// macOS's own speed test, about 20 seconds of upload and download
  /// at once; the result stays on screen a while, since it is read
  /// rather than glanced at.
  func runSpeedtest() {
    guard speedtest?.isRunning != true else {
      return toast(L("speed test already running"))
    }
    toast(L("speed test, about 20 s"), seconds: 3)
    speedtest = Proc.run(
      "/usr/bin/networkQuality", ["-c"], timeout: 90,
      log: "networkQuality"
    ) { [weak self] out in
      self?.speedtest = nil
      self?.toast(
        out.flatMap(Parse.speedtest) ?? L("speed test failed"),
        seconds: 10)
    }
  }

  /// `shortcuts list`, in the background; the old list stays if it
  /// fails.
  func refreshShortcuts() {
    Proc.run("/usr/bin/shortcuts", ["list"], timeout: 10) {
      [weak self] out in
      guard let self, let out else { return }
      self.shortcuts = out.split(separator: "\n").map(String.init)
        .filter { !$0.isEmpty }
    }
  }

  /// Runs one as Shortcuts would; its own dialogs show if it has any.
  func runShortcut(_ name: String) {
    Proc.run(
      "/usr/bin/shortcuts", ["run", name], timeout: 3600,
      log: "shortcuts"
    ) { [weak self] out in
      if out == nil { self?.toast(L("\(name) did not run")) }
    }
  }
}
