import Foundation
import Testing
@testable import Layout

@Test func aReleaseIsItsTagWithoutTheV() {
  #expect(
    Parse.release(#"{"tag_name": "v0.12.0", "name": "tess 0.12.0"}"#)
      == "0.12.0")
  #expect(Parse.release(#"{"tag_name": "0.12.0"}"#) == "0.12.0")
  // What GitHub says when it will not answer.
  #expect(
    Parse.release(#"{"message": "API rate limit exceeded"}"#) == nil)
  #expect(Parse.release("<html>") == nil)
}

@Test func versionsCompareByNumberNotByText() {
  #expect(Parse.isNewer("0.12.0", than: "0.11.0"))
  #expect(Parse.isNewer("0.10.0", than: "0.9.0"))
  #expect(Parse.isNewer("1.0.0", than: "0.99.9"))
  #expect(!Parse.isNewer("0.11.0", than: "0.11.0"))
  // a build ahead of the last release
  #expect(!Parse.isNewer("0.9.0", than: "0.10.0"))
}

@Test func checkingForUpdatesIsOnUnlessTurnedOff() throws {
  #expect(Config.defaults.updateCheck)
  #expect(
    try !Config.load(Data(#"{"update_check": false}"#.utf8))
      .updateCheck)
  var edited = Config.defaults.raw
  edited.updateCheck = false
  let file = try Config.file(for: edited)
  #expect(try !Config.load(file).updateCheck)
  #expect(try Command.parse("update") == [.update])
  #expect(Command.update.description == "update")
}
