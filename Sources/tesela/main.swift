import AppKit
import ApplicationServices
import Layout

let usage = """
  tesela: a tiling window manager for macOS

    tesela serve            run it (the LaunchAgent does this)
    tesela doctor           check permissions, configuration and external binaries
    tesela <command>        send a command to the running tesela, e.g. `tesela focus left`
    tesela tree             print screens, columns and windows
    tesela state            print the model and the machine as JSON
    tesela default-config   print the built-in config (~/.config/tesela/config.json only needs what differs)
    tesela --version        print the version

  """

@MainActor
func serve() -> Never {
  // A CLI that gave up before its answer must not take the app down
  // with it.
  signal(SIGPIPE, SIG_IGN)
  if Socket.send("nop") != nil {
    print("tesela is already running")
    exit(0)
  }
  // ponytail: a kill or crash skips atexit; the LaunchAgent restart
  // lands here and lets the lid sleep the Mac again.
  Tiler.lidSleep(true)
  atexit { Tiler.lidSleep(true) }
  let app = NSApplication.shared
  app.setActivationPolicy(.accessory)
  Tiler.applyLanguage()
  let tiler = Tiler()
  tiler.watchLid()
  let status = StatusItem(tiler)
  tiler.onChange = { status.refreshIcon() }
  tiler.onLayout = { status.refreshIcon() }
  do {
    try Socket.serve { line in
      do {
        return tiler.run(try Command.parse(line), source: "cli")
      } catch { return "error: \(error)" }
    }
  } catch {
    Log.write("\(error)")
  }
  Watchdog.start()
  let hung = Watchdog.restartedAfterHang()
  let begin: @MainActor @Sendable () -> Void = {
    status.waitingForAccess = false
    tiler.start(restartedAfterHang: hung)
    status.refreshIcon()
  }
  if AXIsProcessTrustedWithOptions(
    ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  {
    begin()
  } else {
    status.waitingForAccess = true
    status.refreshIcon()
    Log.write("waiting for Accessibility access")
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
      guard AXIsProcessTrusted() else { return }
      t.invalidate()
      MainActor.assumeIsolated { begin() }
    }
  }
  app.run()
  exit(0)
}

/// Opened as an app (Finder, Spotlight): the running tesela shows its
/// Settings; else its LaunchAgent starts it, so a crash still
/// restarts it; else this process becomes tesela.
@MainActor
func openApp() -> Never {
  if Socket.send("settings") != nil { exit(0) }
  for label in ["com.jonaprieto.tesela", "homebrew.mxcl.tesela"] {
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
case nil
where isatty(STDIN_FILENO) == 0
  && Bundle.main.bundleURL.pathExtension == "app":
  MainActor.assumeIsolated { openApp() }
case nil, "-h", "--help", "help":
  print(usage, terminator: "")
case "--version", "version":
  print("tesela \(version)")
case "default-config":
  print(Config.defaultJSON)
case "doctor":
  exit(Doctor.run())
case "serve":
  MainActor.assumeIsolated { serve() }
default:
  guard let reply = Socket.send(args.joined(separator: " ")) else {
    FileHandle.standardError.write(
      Data(
        "tesela is not running (start it with `tesela serve` or `make install`)\n"
          .utf8))
    exit(1)
  }
  print(reply, terminator: "")
  exit(reply.hasPrefix("error:") ? 1 : 0)
}
