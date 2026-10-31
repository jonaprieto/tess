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

    static var tools: [Tool] { [
        Tool(name: "folio", feature: L("book and paper search/download"), required: true, install: "brew install jonaprieto/tap/folio"),
        Tool(name: "rg", feature: L("search inside files"), required: false, install: "brew install ripgrep"),
        Tool(name: "fzf", feature: L("file-result ranking (Spotlight works without it)"), required: false, install: "brew install fzf"),
    ] + [
        ("/bin/sh", L("shell commands")), ("/bin/launchctl", L("login service")), ("/usr/bin/open", L("opening apps and documents")),
        ("/usr/bin/osascript", L("browser tabs and volume")), ("/usr/bin/mdfind", L("file search")),
        ("/usr/bin/grep", L("file filtering")), ("/usr/bin/head", L("search result limits")),
        ("/usr/bin/sqlite3", L("browser history")), ("/usr/bin/shortcuts", L("Apple Shortcuts")),
        ("/usr/sbin/networksetup", L("Wi-Fi controls")), ("/usr/bin/networkQuality", L("speed test")),
        ("/usr/bin/pmset", L("sleep")), ("/usr/bin/pkill", L("stopping timed-out helper processes")),
    ].map { Tool(name: $0.0, feature: $0.1, required: true, install: L("provided by macOS")) } }

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
            lines.append("[\(ok ? "OK" : required ? L("MISSING") : L("OPTIONAL"))] \(message)")
            if !ok && required { failures += 1 }
        }
        lines.append(L("Tess doctor — no settings are changed\n"))
        check(ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27, L("macOS 27 or later"))
        check(AXIsProcessTrusted(), L("Accessibility access for this Tess binary (System Settings → Privacy & Security → Accessibility)"))
        check(serviceRunning ?? (Socket.send("nop") != nil), L("Tess service running — start with brew services start tess, or make install"), required: false)
        lines.append(L("\nBinaries (service PATH: \(Proc.env["PATH"]!))"))
        for tool in tools {
            let found = executable(tool.name)
            check(found != nil, "\(tool.name): \(found ?? tool.install) — \(tool.feature)", required: tool.required)
        }
        do {
            let data = FileManager.default.fileExists(atPath: Tiler.configURL.path) ? try Data(contentsOf: Tiler.configURL) : nil
            let config = try Config.load(data)
            check(true, L("Configuration parses"))
            check(NSWorkspace.shared.urlForApplication(withBundleIdentifier: config.terminal) != nil
                  || NSWorkspace.shared.fullPath(forApplication: config.terminal) != nil,
                  L("Terminal app: \(config.terminal) — install it or set terminal in ~/.config/tess/config.json"), required: false)
        } catch { check(false, L("Configuration: \(error)")) }
        lines.append(L("\nAny standard Mac keyboard works; no NuPhy software or Hyper key is required."))
        lines.append(L("Browser Automation/Full Disk Access and network download availability are not tested."))
        lines.append(L("\(failures) required check(s) missing. Optional tools only affect their named features."))
        return (lines.joined(separator: "\n"), failures == 0 ? 0 : 1)
    }

    static func run() -> Int32 {
        Tiler.applyLanguage()
        let result = report()
        print(result.text)
        return result.status
    }
}

final class DoctorWindow: NSWindowController {
    private let text = NSTextView()
    private let again = NSButton(title: "", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
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
        again.target = self
        again.action = #selector(runAgain)
        again.bezelStyle = .rounded
        again.frame = NSRect(x: 16, y: 20, width: 150, height: 32)
        window.contentView?.addSubview(scroll)
        window.contentView?.addSubview(again)
    }
    required init?(coder: NSCoder) { nil }

    func show() {
        window?.title = L("Tess Doctor")
        again.title = L("Run Again")
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
