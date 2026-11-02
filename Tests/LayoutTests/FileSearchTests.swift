import Foundation
import Layout
import Testing

/// Runs the script with stand-ins for the tools it names, and only
/// those: what is not in `tools` is not installed.
private func fileSearch(
  _ query: String, tools: [String: String]
) throws -> [String] {
  let manager = FileManager.default
  let bin = manager.temporaryDirectory
    .appendingPathComponent("tess-file-search-\(UUID())")
  try manager.createDirectory(
    at: bin, withIntermediateDirectories: true)
  defer { try? manager.removeItem(at: bin) }
  for (name, body) in tools {
    let tool = bin.appendingPathComponent(name)
    try "#!/bin/sh\n\(body)\n".write(
      to: tool, atomically: true, encoding: .utf8)
    try manager.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: tool.path)
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = ["-c", Parse.fileSearch, "sh", query]
  process.environment = [
    "PATH": "\(bin.path):/usr/bin:/bin", "HOME": "/home"
  ]
  let out = Pipe()
  process.standardOutput = out
  try process.run()
  let data = out.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return String(decoding: data, as: UTF8.self)
    .split(separator: "\n").map(String.init)
}

@Test func fileSearchMergesTheHomeWalkAndSpotlight() throws {
  // Spotlight is asked about the whole Mac, not just the home folder.
  let found = try fileSearch(
    "notes",
    tools: [
      "fd": "echo /home/notes/",
      "mdfind": """
      [ "$1" = -name ] && [ "$2" = notes ] || exit 1
      echo /home/notes
      echo /Library/notes.txt
      """
    ])
  #expect(found == ["/home/notes", "/Library/notes.txt"])
}

@Test func fileSearchFallsBackToSpotlightWithoutFd() throws {
  let found = try fileSearch(
    "notes", tools: ["mdfind": "echo /home/notes.txt"])
  #expect(found == ["/home/notes.txt"])
}

@Test func fileSearchStillAnswersWhenSpotlightHasNothing() throws {
  let found = try fileSearch(
    "new", tools: ["fd": "echo /home/new.txt", "mdfind": "exit 0"])
  #expect(found == ["/home/new.txt"])
}

@Test func fileSearchTakesTheTextLiterally() throws {
  // Fixed strings and `--`: a parenthesis is no bad regular
  // expression, and a leading dash is no flag.
  let fd = """
    case " $* " in *" -F "*) ;; *) exit 1 ;; esac
    while [ "$1" != -- ]; do shift; done
    echo "/home/$2"
    """
  let found = try fileSearch(
    "-a(b", tools: ["fd": fd, "mdfind": "exit 0"])
  #expect(found == ["/home/-a(b"])
}

@Test func fileSearchRanksWithFzfAfterMerging() throws {
  let found = try fileSearch(
    "x",
    tools: [
      "fd": "echo /home/a", "mdfind": "echo /home/b",
      "fzf": "tail -r"
    ])
  #expect(found == ["/home/b", "/home/a"])
}

@Test func fileSearchRanksEverythingAndShowsSixty() throws {
  // The best match can be anywhere: nothing is cut before ranking.
  let found = try fileSearch(
    "x",
    tools: [
      "fd": "seq 1 1000 | sed 's:^:/home/:'", "mdfind": "exit 0",
      "fzf": "tail -r"
    ])
  #expect(found.count == 60)
  #expect(found.first == "/home/1000")
}
