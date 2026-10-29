import AppKit
import ApplicationServices
import Layout

enum Doctor {
    struct Tool {
        let name: String
        let feature: String
        let required: Bool
        let install: String
    }

    static let tools: [Tool] = [
        Tool(name: "folio", feature: "book and paper search/download", required: true, install: "brew install jonaprieto/tap/folio"),
        Tool(name: "rg", feature: "search inside files", required: false, install: "brew install ripgrep"),
        Tool(name: "fzf", feature: "file-result ranking (Spotlight works without it)", required: false, install: "brew install fzf"),
    ] + [
        ("/bin/sh", "shell commands"), ("/bin/launchctl", "login service"), ("/usr/bin/open", "opening apps and documents"),
        ("/usr/bin/osascript", "browser tabs and volume"), ("/usr/bin/mdfind", "file search"),
        ("/usr/bin/grep", "file filtering"), ("/usr/bin/head", "search result limits"),
        ("/usr/bin/sqlite3", "browser history"), ("/usr/bin/shortcuts", "Apple Shortcuts"),
        ("/usr/sbin/networksetup", "Wi-Fi controls"), ("/usr/bin/networkQuality", "speed test"),
        ("/usr/bin/pmset", "sleep"), ("/usr/bin/pkill", "stopping timed-out helper processes"),
    ].map { Tool(name: $0.0, feature: $0.1, required: true, install: "provided by macOS") }

    /// Uses the service's PATH, not a login shell that could hide a missing dependency.
    static func executable(_ name: String, path: String = Proc.env["PATH"]!) -> String? {
        let candidates = name.hasPrefix("/") ? [name] : path.split(separator: ":").map { "\($0)/\(name)" }
        return candidates.first {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &directory)
                && !directory.boolValue && FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    static func report(serviceRunning: Bool? = nil) -> (text: String, status: Int32) {
        var failures = 0
        var lines: [String] = []
        func check(_ ok: Bool, _ message: String, required: Bool = true) {
            lines.append("[\(ok ? "OK" : required ? "MISSING" : "OPTIONAL")] \(message)")
            if !ok && required { failures += 1 }
        }
        lines.append("Tess doctor — no settings are changed\n")
        check(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27, "macOS 27 or later")
        check(AXIsProcessTrusted(), "Accessibility access for this Tess binary (System Settings → Privacy & Security → Accessibility)")
        check(serviceRunning ?? (Socket.send("nop") != nil), "Tess service running — start with brew services start tess, or make install", required: false)
        lines.append("\nBinaries (service PATH: \(Proc.env["PATH"]!))")
        for tool in tools {
            let found = executable(tool.name)
            check(found != nil, "\(tool.name): \(found ?? tool.install) — \(tool.feature)", required: tool.required)
        }
        do {
            let data = FileManager.default.fileExists(atPath: Tiler.configURL.path) ? try Data(contentsOf: Tiler.configURL) : nil
            let config = try Config.load(data)
            check(true, "Configuration parses")
            check(NSWorkspace.shared.urlForApplication(withBundleIdentifier: config.terminal) != nil
                  || NSWorkspace.shared.fullPath(forApplication: config.terminal) != nil,
                  "Terminal app: \(config.terminal) — install it or set terminal in ~/.config/tess/config.json", required: false)
        } catch { check(false, "Configuration: \(error)") }
        lines.append("\nAny standard Mac keyboard works; no NuPhy software or Hyper key is required.")
        lines.append("Browser Automation/Full Disk Access and network download availability are not tested.")
        lines.append("\(failures) required check(s) missing. Optional tools only affect their named features.")
        return (lines.joined(separator: "\n"), failures == 0 ? 0 : 1)
    }

    static func run() -> Int32 {
        let result = report()
        print(result.text)
        return result.status
    }
}

final class DoctorWindow: NSWindowController {
    private let text = NSTextView()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Tess Doctor"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 64, width: 728, height: 440))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        text.frame = scroll.contentView.bounds
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        let refresh = NSButton(title: "Run Again", target: self, action: #selector(runAgain))
        refresh.bezelStyle = .rounded
        refresh.frame = NSRect(x: 16, y: 20, width: 112, height: 32)
        window.contentView?.addSubview(scroll)
        window.contentView?.addSubview(refresh)
    }
    required init?(coder: NSCoder) { nil }

    func show() {
        runAgain()
        window?.center()
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func runAgain() {
        // Already inside the service: pinging its socket here would block its own main thread.
        text.string = Doctor.report(serviceRunning: true).text
        text.scrollToBeginningOfDocument(nil)
    }
}
