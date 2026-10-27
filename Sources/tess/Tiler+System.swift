import AppKit
import IOKit.pwr_mgt
import Layout

/// The Mac's own switches, as commands: volume, Wi-Fi and caffeine, and the person's
/// Shortcuts, which the picker lists.
extension Tiler {
    /// Through AppleScript's `set volume`, which needs no permission.
    func setVolume(_ v: Volume) {
        let change = switch v {
        case .level(let n): "set volume output volume \(n) without output muted"
        case .step(let n): "set volume output volume ((output volume of (get volume settings)) + \(n)) without output muted"
        case .mute: "set volume with output muted"
        case .unmute: "set volume without output muted"
        }
        let report = "set s to get volume settings\nif output muted of s then return \"muted\"\nreturn \"volume \" & (output volume of s) & \"%\""
        var error: NSDictionary?
        let now = NSAppleScript(source: change + "\n" + report)?.executeAndReturnError(&error)
        toast(error == nil ? now?.stringValue ?? "volume changed" : "volume did not change")
    }

    /// Through `networksetup` on the Wi-Fi device; nil turns it the other way round.
    func setWifi(_ on: Bool?) {
        let tool = "/usr/sbin/networksetup"
        Proc.run(tool, ["-listallhardwareports"], timeout: 5) { [weak self] out in
            guard let self, let device = out.flatMap(Parse.wifiDevice) else { return self?.toast("no Wi-Fi here") ?? () }
            func set(_ on: Bool) {
                Proc.run(tool, ["-setairportpower", device, on ? "on" : "off"], timeout: 10, log: "networksetup") { [weak self] r in
                    self?.toast(r == nil ? "Wi-Fi did not change" : "Wi-Fi \(on ? "on" : "off")")
                }
            }
            if let on { return set(on) }
            Proc.run(tool, ["-getairportpower", device], timeout: 5) { out in
                set(!(out.flatMap(Parse.wifiPower) ?? false))
            }
        }
    }

    /// A display-sleep assertion, which keeps the system awake too, for `minutes` or until
    /// turned off; `caffeine` alone turns it off when it is on. Released when tess quits.
    func setCaffeine(_ minutes: Int?) {
        let wasOn = caffeine != nil
        if let c = caffeine { IOPMAssertionRelease(c.id) }
        caffeine = nil
        caffeineTimer?.invalidate()
        caffeineTimer = nil
        defer { onChange() }
        if minutes == 0 || (minutes == nil && wasOn) { return toast("caffeine off") }
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                          IOPMAssertionLevel(kIOPMAssertionLevelOn), "tess caffeine" as CFString,
                                          &id) == kIOReturnSuccess
        else { return toast("caffeine did not start") }
        let until = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        caffeine = (id, until)
        if let until {
            caffeineTimer = Timer.scheduledTimer(withTimeInterval: until.timeIntervalSinceNow, repeats: false) { [weak self] _ in
                self?.setCaffeine(0)
            }
        }
        toast(minutes.map { "caffeine for \($0) min" } ?? "caffeine on")
    }

    /// macOS's own speed test, about 20 seconds of upload and download at once; the result
    /// stays on screen a while, since it is read rather than glanced at.
    func runSpeedtest() {
        guard speedtest?.isRunning != true else { return toast("speed test already running") }
        toast("speed test, about 20 s", seconds: 3)
        speedtest = Proc.run("/usr/bin/networkQuality", ["-c"], timeout: 90, log: "networkQuality") { [weak self] out in
            self?.speedtest = nil
            self?.toast(out.flatMap(Parse.speedtest) ?? "speed test failed", seconds: 10)
        }
    }

    /// `shortcuts list`, in the background; the old list stays if it fails.
    func refreshShortcuts() {
        Proc.run("/usr/bin/shortcuts", ["list"], timeout: 10) { [weak self] out in
            guard let self, let out else { return }
            self.shortcuts = out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
    }

    /// Runs one as Shortcuts would; its own dialogs show if it has any.
    func runShortcut(_ name: String) {
        Proc.run("/usr/bin/shortcuts", ["run", name], timeout: 3600, log: "shortcuts") { [weak self] out in
            if out == nil { self?.toast("\(name) did not run") }
        }
    }
}
