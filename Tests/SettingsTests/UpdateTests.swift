import AppKit
import Layout
import Testing
@testable import tesela

@Test func onlyACopyInHomebrewsCellarCountsAsHomebrew() throws {
  #expect(
    Tiler.homebrew("/opt/homebrew/Cellar/tesela/0.11.0/bin/tesela")
      == "/opt/homebrew")
  #expect(Tiler.homebrew("/Users/someone/tesela/build/tesela") == nil)
  #expect(
    Tiler.homebrew("/Applications/tesela.app/Contents/MacOS/tesela")
      == nil)
  #expect(Tiler.homebrew(nil) == nil)
  // Started by launchd through `opt`, a link into the Cellar.
  let root = try fakeHomebrew(installs: "0.11.0")
  defer { try? FileManager.default.removeItem(at: root) }
  #expect(
    Tiler.homebrew(root.path + "/opt/tesela/bin/tesela")?.hasSuffix(
      root.lastPathComponent) == true)
}

@MainActor
@Test func aNewerVersionShowsOnceAndAnOlderOneNot() throws {
  _ = NSApplication.shared
  UserDefaults.standard.removeObject(forKey: "announcedUpdate")
  defer {
    UserDefaults.standard.removeObject(forKey: "announcedUpdate")
  }
  let tiler = Tiler()
  var changes = 0
  tiler.onChange = { changes += 1 }
  tiler.heard("0.9.0", running: "0.11.0")
  #expect(tiler.update == nil)
  #expect(changes == 0)
  tiler.heard("0.12.0", running: "0.11.0")
  #expect(tiler.update == "0.12.0")
  #expect(changes == 1)
  #expect(
    UserDefaults.standard.string(forKey: "announcedUpdate")
      == "0.12.0")
  tiler.heard("0.12.0", running: "0.11.0")
  #expect(changes == 1)
  tiler.heard("0.11.0", running: "0.11.0")  // the release was pulled
  #expect(tiler.update == nil)
}

@MainActor
@Test func aDayGoesByBeforeGitHubIsAskedAgainAndNeverWhenTurnedOff() {
  _ = NSApplication.shared
  let tiler = Tiler()
  tiler.updateChecked = Date()
  // would be a request, and an answer that never comes in a test
  tiler.checkForUpdate()
  tiler.config.updateCheck = false
  tiler.updateChecked = .distantPast
  tiler.checkForUpdate()
  #expect(tiler.update == nil)
}

@MainActor
@Test func theMenuOffersTheUpdateOnlyWhenThereIsOne() throws {
  _ = NSApplication.shared
  let tiler = Tiler()
  let status = StatusItem(tiler)
  let menu = NSMenu()
  status.menuNeedsUpdate(menu)
  #expect(!menu.items.contains { $0.title.hasPrefix("Update to") })
  tiler.update = "99.0.0"
  status.menuNeedsUpdate(menu)
  let item = try #require(
    menu.items.first { $0.title == "Update to 99.0.0" })
  #expect(item.action != nil)
  #expect(item.subtitle?.isEmpty == false)
  status.refreshIcon()  // with its dot
}

/// A prefix whose `brew` writes down how it was called and whose
/// installed tesela is `installs`.
private func fakeHomebrew(installs: String, brewFails: Bool = false)
  throws -> URL
{
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .resolvingSymlinksInPath()
  let cellar = root.appendingPathComponent(
    "Cellar/tesela/\(installs)/bin")
  let fm = FileManager.default
  try fm.createDirectory(
    at: cellar, withIntermediateDirectories: true)
  try fm.createDirectory(
    at: root.appendingPathComponent("bin"),
    withIntermediateDirectories: true)
  try fm.createDirectory(
    at: root.appendingPathComponent("opt"),
    withIntermediateDirectories: true)
  try fm.createSymbolicLink(
    atPath: root.appendingPathComponent("opt/tesela").path,
    withDestinationPath: "../Cellar/tesela/\(installs)")
  let brew = root.appendingPathComponent("bin/brew"),
    tesela = cellar.appendingPathComponent("tesela")
  try
    "#!/bin/sh\necho \"$* [$HOMEBREW_NO_AUTO_UPDATE]\" >> \"\(root.path)/calls\"\nexit \(brewFails ? 1 : 0)\n"
    .write(
      to: brew, atomically: true, encoding: .utf8)
  try "#!/bin/sh\necho \"tesela \(installs)\"\n".write(
    to: tesela, atomically: true, encoding: .utf8)
  for file in [brew, tesela] {
    try fm.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: file.path)
  }
  return root
}

@MainActor
private func install(
  _ new: String, from root: URL, restarts: Bool = true
) async -> (tiler: Tiler, restarted: Int) {
  _ = NSApplication.shared
  let tiler = Tiler()
  var restarted = 0
  tiler.restart = {
    restarted += 1
    return restarts
  }
  tiler.install(new, homebrew: root.path)
  #expect(tiler.updating)
  let until = Date().addingTimeInterval(5)
  while tiler.updating, Date() < until {
    try? await Task.sleep(for: .milliseconds(20))
  }
  #expect(!tiler.updating)
  return (tiler, restarted)
}

// They share the `updatedTo` default: one at a time.
@Suite(.serialized) struct HomebrewInstall {
  @MainActor
  @Test
  func homebrewUpdatesAndTeselaRestartsOnlyOnceTheNewVersionIsThere()
    async throws
  {
    UserDefaults.standard.removeObject(forKey: "updatedTo")
    defer { UserDefaults.standard.removeObject(forKey: "updatedTo") }
    let root = try fakeHomebrew(installs: "99.0.0")
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, restarted) = await install("99.0.0", from: root)
    #expect(restarted == 1)
    #expect(
      UserDefaults.standard.string(forKey: "updatedTo") == "99.0.0")
    let calls = try String(
      contentsOf: root.appendingPathComponent("calls"),
      encoding: .utf8)
    #expect(
      calls
        == "update --quiet []\nupgrade jonaprieto/tap/tesela [1]\n")
  }

  @MainActor
  @Test func aReleaseHomebrewDoesNotHaveYetLeavesTeselaRunning()
    async throws
  {
    UserDefaults.standard.removeObject(forKey: "updatedTo")
    let root = try fakeHomebrew(installs: "0.11.0")
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, restarted) = await install("99.0.0", from: root)
    #expect(restarted == 0)
    #expect(UserDefaults.standard.string(forKey: "updatedTo") == nil)
  }

  @MainActor
  @Test
  func aFailingBrewChangesNothingUnlessTheNewVersionGotInstalled()
    async throws
  {
    UserDefaults.standard.removeObject(forKey: "updatedTo")
    defer { UserDefaults.standard.removeObject(forKey: "updatedTo") }
    let old = try fakeHomebrew(installs: "0.11.0", brewFails: true)
    defer { try? FileManager.default.removeItem(at: old) }
    #expect(await install("99.0.0", from: old).restarted == 0)
    // `brew update` failing offline must not stop a tap that already
    // has it.
    let fine = try fakeHomebrew(installs: "99.0.0", brewFails: true)
    defer { try? FileManager.default.removeItem(at: fine) }
    #expect(await install("99.0.0", from: fine).restarted == 1)
  }

  @MainActor
  @Test func notUnderLaunchdItSaysToRestartInsteadOfExiting()
    async throws
  {
    let root = try fakeHomebrew(installs: "99.0.0")
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removeObject(forKey: "updatedTo")
    }
    let (tiler, restarted) = await install(
      "99.0.0", from: root, restarts: false)
    #expect(restarted == 1)
    #expect(
      tiler.overlay.downloads.first?.status
        == "Restart tesela to finish")
  }
}
