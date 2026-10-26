import AppKit
import Layout

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
                let items = (output ?? "").split(separator: "\n").compactMap(Parse.tab).map { t in
                    let host = URL(string: t.url)?.host ?? t.url
                    return Picker.Item(kind: .tab(.init(bundleID: bundleID, window: t.window, index: t.index)),
                                       title: t.title, detail: "\(name) tab · \(host)", icon: icon, search: "\(t.title) \(t.url)")
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
                let items = (text ?? "").split(separator: "\n").compactMap(Parse.page).map { p in
                    Picker.Item(kind: .url(p.url, browser: source.browser), title: p.title,
                                detail: "\(name) \(source.kind) · \(p.host)", icon: icon,
                                search: "\(p.title) \(p.host) \(p.url.path)", quiet: true)
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

    /// Read-only query on an immutable snapshot of the file; tab separated, nil on failure.
    static func sqlite(_ uri: String, _ query: String, onMain: Bool = true, _ done: @escaping (String?) -> Void) {
        Proc.run("/usr/bin/sqlite3", ["-readonly", "-separator", "\t", uri, query], timeout: 10, onMain: onMain,
                 log: "sqlite", done)
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

    /// A browser stuck on a dialog would otherwise hold this for the 2 minute Apple event timeout.
    static func osascript(_ script: String, onMain: Bool = true, _ done: @escaping (String?) -> Void) {
        Proc.run("/usr/bin/osascript", ["-e", script], timeout: 10, onMain: onMain, log: "osascript", done)
    }
}
