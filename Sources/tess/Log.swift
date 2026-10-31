import Foundation

/// Append-only `~/Library/Logs/tess.log`, started over when it passes
/// 5 MB (checked as it grows). Written on a queue of its own: done on
/// the caller it took half a millisecond of every key.
enum Log {
  static let url = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/tess.log")
  private static let queue = DispatchQueue(
    label: "tess.log", qos: .utility)
  // The queue only.
  nonisolated(unsafe) private static var written = 0
  nonisolated(unsafe) private static var handle: FileHandle? = open()
  // Thread-safe, though not marked Sendable.
  nonisolated(unsafe) private static let time: ISO8601DateFormatter =
    {
      let f = ISO8601DateFormatter()
      f.timeZone = .current
      f.formatOptions = [
        .withInternetDateTime, .withFractionalSeconds
      ]
      return f
    }()

  private static func open() -> FileHandle? {
    let fm = FileManager.default
    if let size = try? fm.attributesOfItem(atPath: url.path)[.size]
      as? Int, size > 5_000_000
    {
      try? fm.removeItem(at: url)
    }
    if !fm.fileExists(atPath: url.path) {
      fm.createFile(atPath: url.path, contents: nil)
    }
    let h = try? FileHandle(forWritingTo: url)
    written = Int((try? h?.seekToEnd()) ?? 0)
    return h
  }

  static func write(_ message: String) {
    let line = "\(time.string(from: Date())) \(message)\n"
    queue.async {
      if written > 5_000_000 {
        try? handle?.close()
        try? FileManager.default.removeItem(at: url)
        handle = open()
      }
      // The throwing write: the old one raises an Objective-C
      // exception on a full disk.
      try? handle?.write(contentsOf: Data(line.utf8))
      written += line.utf8.count
    }
  }

  /// Everything written so far is on disk, for a process about to
  /// exit.
  static func flush() { queue.sync {} }
}
