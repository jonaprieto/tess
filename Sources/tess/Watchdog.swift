import Foundation

/// The failure tiling window managers show most: alive, but hotkeys
/// dead. A background thread watches a main-thread heartbeat; after 5
/// s without one, tess exits and launchd starts it again. Nothing is
/// ever hidden, so restarting costs nothing but the restart.
enum Watchdog {
  /// Present after a watchdog exit, so the next run can say so.
  static let marker = Socket.dir.appendingPathComponent("hung")
  private static let lock = NSLock()
  // Uptime stops while the Mac sleeps, so sleep is not mistaken for a
  // hang.
  nonisolated(unsafe) private static var last: UInt64 = 0

  static func start() {
    last = DispatchTime.now().uptimeNanoseconds
    let beat = Timer(timeInterval: 2, repeats: true) { _ in
      lock.lock()
      last = DispatchTime.now().uptimeNanoseconds
      lock.unlock()
    }
    // Tolerance lets macOS batch the wakeup with others.
    beat.tolerance = 1
    // Common modes: the heartbeat keeps going while the status menu
    // is open.
    RunLoop.main.add(beat, forMode: .common)
    let thread = Thread {
      while true {
        Thread.sleep(forTimeInterval: 3)
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let stalled = now > last && now - last > 5_000_000_000
        lock.unlock()
        if stalled {
          Log.write("watchdog: main thread stalled for 5 s, exiting")
          Events.record(
            "watchdog", ["stalled_s": 5, "machine": Events.machine()])
          Log.flush()
          Events.flush()
          FileManager.default.createFile(
            atPath: marker.path, contents: nil)
          exit(1)
        }
      }
    }
    thread.name = "tess.watchdog"
    thread.start()
  }

  /// Whether the previous run ended in a watchdog exit (and forget
  /// it).
  static func restartedAfterHang() -> Bool {
    defer { try? FileManager.default.removeItem(at: marker) }
    return FileManager.default.fileExists(atPath: marker.path)
  }
}
