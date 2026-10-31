import Foundation
import Layout

/// The operation log, for improving tess from what really happened:
/// one JSON object per line in `~/Library/Logs/tess/events.jsonl`,
/// `{"t": time, "e": type, ...fields}`. Rotated at 20 MB, keeping one
/// previous file. It stays on this Mac; picker queries are not
/// recorded.
enum Events {
  static let dir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/tess")
  static let url = dir.appendingPathComponent("events.jsonl")
  private static let lock = NSLock()
  /// Writes happen here, so a slow disk or a rotation never stalls
  /// the main thread.
  private static let queue = DispatchQueue(
    label: "tess.events", qos: .utility)
  nonisolated(unsafe) private static var handle: FileHandle?
  nonisolated(unsafe) private static var written = 0
  private static let time: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  static func record(_ type: String, _ fields: [String: Any] = [:]) {
    var event = fields
    event["e"] = type
    lock.lock()
    defer { lock.unlock() }
    event["t"] = time.string(from: Date())
    guard JSONSerialization.isValidJSONObject(event),
      var line = try? JSONSerialization.data(
        withJSONObject: event,
        options: [.sortedKeys, .withoutEscapingSlashes])
    else { return }
    line.append(0x0A)
    queue.async {
      lock.lock()
      defer { lock.unlock() }
      if handle == nil || written > 20_000_000 {
        reopen(rotate: handle != nil)
      }
      try? handle?.write(contentsOf: line)
      written += line.count
    }
  }

  private static func reopen(rotate: Bool) {
    let fm = FileManager.default
    try? handle?.close()
    try? fm.createDirectory(
      at: dir, withIntermediateDirectories: true)
    if rotate {
      let old = dir.appendingPathComponent("events.1.jsonl")
      try? fm.removeItem(at: old)
      try? fm.moveItem(at: url, to: old)
    }
    if !fm.fileExists(atPath: url.path) {
      fm.createFile(atPath: url.path, contents: nil)
    }
    handle = try? FileHandle(forWritingTo: url)
    written = Int((try? handle?.seekToEnd()) ?? 0)
  }

  /// The machine as tess sees it, for state snapshots.
  static func machine() -> [String: Any] {
    let p = ProcessInfo.processInfo
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let cpu =
      Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(
        usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    let thermal = ["nominal", "fair", "serious", "critical"][
      min(p.thermalState.rawValue, 3)]
    return [
      "macos": p.operatingSystemVersionString,
      "uptime_s": Int(p.systemUptime),
      "thermal": thermal,
      "low_power": p.isLowPowerModeEnabled,
      "memory_gb": Double(p.physicalMemory) / 1_073_741_824,
      "tess_cpu_s": (cpu * 100).rounded() / 100,
      "tess_rss_mb": Int(usage.ru_maxrss) / 1_048_576
    ]
  }
}
