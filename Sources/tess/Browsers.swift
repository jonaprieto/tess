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
                            -- Two Apple events per window, not two per tab.
                            set ts to \(titleKey) of tabs of w
                            set us to URL of tabs of w
                            repeat with i from 1 to count of ts
                                set out to out & wid & sep & i & sep & (item i of ts) & sep & (item i of us) & linefeed
                            end repeat
                        end try
                    end repeat
                end tell
                return out
                """
            osascript(script, onMain: false) { output in
                let name = app.localizedName ?? bundleID
                let icon = Icons.small(app.icon)
                let items = (output ?? "").split(separator: "\n").compactMap { line -> Picker.Item? in
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    guard f.count >= 4, let w = Int(f[0]), let i = Int(f[1]) else { return nil }
                    let host = URL(string: f[3])?.host ?? f[3]
                    return Picker.Item(kind: .tab(.init(bundleID: bundleID, window: w, index: i)),
                                       title: f[2].isEmpty ? f[3] : f[2], detail: "\(name) tab · \(host)",
                                       icon: icon, search: "\(f[2]) \(f[3])")
                }
                DispatchQueue.main.async { done(items) }
            }
        }
    }

    /// Pages for the picker, only listed once something is typed: Brave bookmarks (AppleScript),
    /// then Brave and Safari history by visit count (sqlite, read-only). Brave's history needs
    /// macOS's "data from other apps" consent and Safari's Full Disk Access; without them that
    /// source is skipped. Read again after five minutes.
    nonisolated(unsafe) private static var cache: (items: [Picker.Item], at: Date)?

    static func history(_ done: @escaping ([Picker.Item]) -> Void) {
        if let c = cache, Date().timeIntervalSince(c.at) < 300 { return done(c.items) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let brave = "com.brave.Browser", safari = "com.apple.Safari"
        let bookmarks = """
            set sep to character id 9
            on walk(f, sep)
                set out to ""
                tell application id "com.brave.Browser"
                    -- Two Apple events per folder, not two per bookmark.
                    set ts to title of bookmark items of f
                    set us to URL of bookmark items of f
                    repeat with i from 1 to count of ts
                        set out to out & (item i of ts) & sep & (item i of us) & linefeed
                    end repeat
                    repeat with sub in bookmark folders of f
                        set out to out & my walk(sub, sep)
                    end repeat
                end tell
                return out
            end walk
            tell application id "com.brave.Browser" to set roots to {bookmarks bar, other bookmarks}
            set out to ""
            repeat with r in roots
                set out to out & walk(r, sep)
            end repeat
            return out
            """
        let braveRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: brave).isEmpty
        func uri(_ path: String) -> String {
            "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?immutable=1"
        }
        let sources: [(browser: String, kind: String, run: (@escaping (String?) -> Void) -> Void)] = [
            (brave, "bookmark", { braveRunning ? osascript(bookmarks, onMain: false, $0) : $0(nil) }),
            (brave, "history", { sqlite(uri(home + "/Library/Application Support/BraveSoftware/Brave-Browser/Default/History"), """
                select title, url from urls where hidden = 0 order by visit_count + 5 * typed_count desc limit 3000
                """, onMain: false, $0) }),
            (safari, "history", { sqlite(uri(home + "/Library/Safari/History.db"), """
                select coalesce((select title from history_visits v where v.history_item = i.id order by v.visit_time desc limit 1), ''),
                       i.url from history_items i order by i.visit_count desc limit 3000
                """, onMain: false, $0) }),
        ]
        var all: [Picker.Item] = []
        var seen = Set<String>()
        var left = sources.count
        var answered = false
        for source in sources {
            // Parsed where it arrives, off the main thread; merged on it.
            source.run { text in
                let name = source.browser == brave ? "Brave" : "Safari"
                let icon = Icons.small(NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.browser)
                    .map { NSWorkspace.shared.icon(forFile: $0.path) })
                let items = (text ?? "").split(separator: "\n").compactMap { line -> Picker.Item? in
                    let f = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    guard f.count == 2, let url = URL(string: f[1]), url.scheme?.hasPrefix("http") == true else { return nil }
                    let host = url.host ?? f[1]
                    return Picker.Item(kind: .url(url, browser: source.browser), title: f[0].isEmpty ? f[1] : f[0],
                                       detail: "\(name) \(source.kind) · \(host)", icon: icon,
                                       search: "\(f[0]) \(host) \(url.path)", quiet: true)
                }
                // Each source as soon as it answers, without repeats.
                DispatchQueue.main.async {
                    let fresh = items.filter { seen.insert(($0.detail.hasPrefix("Brave") ? "b" : "s") + $0.search).inserted }
                    all += fresh
                    left -= 1
                    if text != nil { answered = true }
                    // Not cached when every source failed (no permission yet): try again next open.
                    if left == 0, answered { cache = (all, Date()) }
                    if !fresh.isEmpty { done(fresh) }
                }
            }
        }
    }

    /// Read-only query on a copy-free immutable snapshot; tab separated, nil on failure.
    static func sqlite(_ uri: String, _ query: String, onMain: Bool = true, _ done: @escaping (String?) -> Void) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            p.arguments = ["-readonly", "-separator", "\t", uri, query]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                deliver(onMain) { done(nil) }
                return
            }
            // A browser stuck on a dialog would otherwise hold this for the 2 minute Apple event timeout.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if p.isRunning { p.terminate() } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let problem = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 { Log.write("sqlite: \(String(decoding: problem, as: UTF8.self).prefix(200))") }
            let text = p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
            deliver(onMain) { done(text) }
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

    static func deliver(_ onMain: Bool, _ block: @escaping () -> Void) {
        if onMain { DispatchQueue.main.async(execute: block) } else { block() }
    }

    static func osascript(_ script: String, onMain: Bool = true, _ done: @escaping (String?) -> Void) {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do { try p.run() } catch {
                deliver(onMain) { done(nil) }
                return
            }
            // A browser stuck on a dialog would otherwise hold this for the 2 minute Apple event timeout.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { if p.isRunning { p.terminate() } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let problem = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 { Log.write("osascript: \(String(decoding: problem, as: UTF8.self))") }
            let text = p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
            deliver(onMain) { done(text) }
        }
    }
}
