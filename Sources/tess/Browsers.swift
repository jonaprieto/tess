import AppKit

/// Brave and Safari tabs over AppleScript, run with `osascript` off the main thread (a busy
/// browser can take seconds to answer, and the watchdog allows the main thread five).
enum Browsers {
    /// Bundle id and the AppleScript name of a tab's title.
    static let all = [("com.brave.Browser", "title"), ("com.apple.Safari", "name")]

    /// Tabs of every running browser; `done` runs on the main thread once per browser.
    static func tabs(_ done: @escaping ([Picker.Item]) -> Void) {
        for (bundleID, titleKey) in all {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let script = """
                set sep to character id 9
                set out to ""
                tell application id "\(bundleID)"
                    repeat with w in windows
                        try
                            set wid to id of w
                            set i to 0
                            repeat with t in tabs of w
                                set i to i + 1
                                set out to out & wid & sep & i & sep & (\(titleKey) of t) & sep & (URL of t) & linefeed
                            end repeat
                        end try
                    end repeat
                end tell
                return out
                """
            osascript(script) { output in
                let name = app.localizedName ?? bundleID
                let items = (output ?? "").split(separator: "\n").compactMap { line -> Picker.Item? in
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard f.count >= 4, let w = Int(f[0]), let i = Int(f[1]) else { return nil }
                    let host = URL(string: f[3])?.host ?? f[3]
                    return Picker.Item(kind: .tab(.init(bundleID: bundleID, window: w, index: i)),
                                       title: f[2].isEmpty ? f[3] : f[2], detail: "\(name) tab · \(host)",
                                       icon: app.icon, search: "\(f[2]) \(f[3])")
                }
                done(items)
            }
        }
    }

    /// Brings the tab to the front of its window and the window to the front of the browser.
    static func select(_ t: Picker.Tab, _ done: @escaping () -> Void) {
        let pick = t.bundleID == "com.apple.Safari"
            ? "set current tab of w to tab \(t.index) of w" : "set active tab index of w to \(t.index)"
        osascript("""
            tell application id "\(t.bundleID)"
                set w to first window whose id is \(t.window)
                \(pick)
                set index of w to 1
                activate
            end tell
            """) { _ in done() }
    }

    static func osascript(_ script: String, _ done: @escaping (String?) -> Void) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                DispatchQueue.main.async { done(nil) }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let problem = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 { Log.write("osascript: \(String(decoding: problem, as: UTF8.self))") }
            let text = p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
            DispatchQueue.main.async { done(text) }
        }
    }
}
