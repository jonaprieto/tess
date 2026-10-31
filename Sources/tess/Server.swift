import Foundation

/// `tess <command>` talks to the running app over a Unix socket: one
/// connection per line, the client closes its write side, the server
/// answers and closes.
enum Socket {
  static let dir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/tess")
  static let path = dir.appendingPathComponent("tess.sock").path

  private static func address() -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      let bytes = Array(path.utf8.prefix(buf.count - 1))
      buf.copyBytes(from: bytes)
      buf[bytes.count] = 0
    }
    return addr
  }

  private static func withAddress<T>(
    _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
  ) -> T {
    var addr = address()
    return withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
  }

  static func readAll(_ fd: Int32) -> String {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = read(fd, &buf, buf.count)
      if n <= 0 { break }
      data.append(buf, count: n)
    }
    return String(decoding: data, as: UTF8.self)
  }

  static func writeAll(_ fd: Int32, _ s: String) {
    var bytes = Array(s.utf8)[...]
    while !bytes.isEmpty {
      let n = bytes.withUnsafeBytes {
        write(fd, $0.baseAddress, $0.count)
      }
      if n <= 0 { return }
      bytes = bytes.dropFirst(n)
    }
  }

  /// The reply, or nil when no tess is listening.
  static func send(_ line: String) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(
      fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
      socklen_t(MemoryLayout<timeval>.size))
    guard withAddress({ connect(fd, $0, $1) }) == 0 else {
      return nil
    }
    writeAll(fd, line + "\n")
    shutdown(fd, SHUT_WR)
    return readAll(fd)
  }

  /// Accepts connections on a background thread; `handler` runs on
  /// the main thread.
  static func serve(
    _ handler: @escaping @MainActor @Sendable (String) -> String
  ) throws {
    try FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0, withAddress({ bind(fd, $0, $1) }) == 0,
      listen(fd, 8) == 0
    else {
      throw NSError(
        domain: NSPOSIXErrorDomain, code: Int(errno),
        userInfo: [
          NSLocalizedDescriptionKey:
            "socket \(path): \(String(cString: strerror(errno)))"
        ])
    }
    let thread = Thread {
      while true {
        let client = accept(fd, nil, nil)
        guard client >= 0 else {
          // a persistent error (out of descriptors) must not spin
          usleep(100_000)
          continue
        }
        // A client that connects and never finishes its line must not
        // block the next one.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(
          client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
          socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(
          client, SOL_SOCKET, SO_NOSIGPIPE, &one,
          socklen_t(MemoryLayout<Int32>.size))
        let line = readAll(client).trimmingCharacters(
          in: .whitespacesAndNewlines)
        var reply = ""
        DispatchQueue.main.sync {
          reply = MainActor.assumeIsolated { handler(line) }
        }
        writeAll(client, reply.isEmpty ? "" : reply + "\n")
        close(client)
      }
    }
    thread.name = "tess.socket"
    thread.start()
  }
}
