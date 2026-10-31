import AppKit
import ApplicationServices
import Layout

let version = "0.11.0"

let usage = """
    tess: a tiling window manager for macOS

      tess serve            run it (the LaunchAgent does this)
      tess doctor           check permissions, configuration and external binaries
      tess tutorial         open the newcomer walkthrough
      tess <command>        send a command to the running tess, e.g. `tess focus left`
      tess tree             print screens, columns and windows
      tess state            print the model and the machine as JSON
      tess default-config   print the built-in config (~/.config/tess/config.json only needs what differs)
      tess --version        print the version

    """

func serve() -> Never {
    // A CLI that gave up before its answer must not take the app down with it.
    signal(SIGPIPE, SIG_IGN)
    if Socket.send("nop") != nil {
        print("tess is already running")
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Tiler.applyLanguage()
    let tiler = Tiler()
    let status = StatusItem(tiler)
    tiler.onChange = { status.refreshIcon() }
    tiler.onLayout = { status.refreshIcon() }
    do {
        try Socket.serve { line in
            do { return tiler.run(try Command.parse(line), source: "cli") } catch { return "error: \(error)" }
        }
    } catch {
        Log.write("\(error)")
    }
    Watchdog.start()
    let hung = Watchdog.restartedAfterHang()
    func begin() {
        status.waitingForAccess = false
        tiler.start(restartedAfterHang: hung)
        status.refreshIcon()
    }
    if AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
        begin()
    } else {
        status.waitingForAccess = true
        status.refreshIcon()
        Log.write("waiting for Accessibility access")
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
            guard AXIsProcessTrusted() else { return }
            t.invalidate()
            begin()
        }
    }
    app.run()
    exit(0)
}

/// Opened as an app (Finder, Spotlight): the running tess shows its Settings; else its
/// LaunchAgent starts it, so a crash still restarts it; else this process becomes tess.
func openApp() -> Never {
    if Socket.send("settings") != nil { exit(0) }
    for label in ["com.jonaprieto.tess", "homebrew.mxcl.tess"] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
        guard (try? p.run()) != nil else { continue }
        p.waitUntilExit()
        if p.terminationStatus == 0 { exit(0) }
    }
    serve()
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case nil where isatty(STDIN_FILENO) == 0 && Bundle.main.bundleURL.pathExtension == "app":
    openApp()
case nil, "-h", "--help", "help":
    print(usage, terminator: "")
case "--version", "version":
    print("tess \(version)")
case "default-config":
    print(Config.defaultJSON)
case "doctor":
    exit(Doctor.run())
case "serve":
    serve()
default:
    guard let reply = Socket.send(args.joined(separator: " ")) else {
        FileHandle.standardError.write(Data("tess is not running (start it with `tess serve` or `make install`)\n".utf8))
        exit(1)
    }
    print(reply, terminator: "")
    exit(reply.hasPrefix("error:") ? 1 : 0)
}
