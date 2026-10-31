import AppKit
import Layout
import Testing
@testable import tess

// Off every real screen, so no overlay of these tests shows up over
// the windows in use.
private let screen = CGRect(
  x: 100_000, y: 100_000, width: 1800, height: 1129)

/// A tiler with `ids` as columns and no app behind them: nothing here
/// reaches a real window.
@MainActor
private func tiler(_ ids: [WindowID], focused: WindowID? = nil)
  -> Tiler
{
  _ = NSApplication.shared
  let tiler = Tiler()
  tiler.starting = false
  tiler.world.monitors = [Monitor(id: "A", frame: screen)]
  tiler.world.monitors[0].lanes = ids.map { Lane([$0]) }
  tiler.world.focused = focused
  for id in ids {
    tiler.infos[id] = WinInfo(
      id: id, pid: 1, frame: .zero, title: "", standard: true,
      fullscreenButton: true, nativeFullscreen: false)
  }
  return tiler
}

@MainActor
@Test func pausedOnlyLetsThroughWhatStillMakesSense() {
  let t = tiler([1], focused: 1)
  t.paused = true
  #expect(t.execute(.balance).hasPrefix("error: "))
  #expect(t.execute(.accordion).hasPrefix("error: "))
  #expect(!t.execute(.tree).hasPrefix("error: "))
}

@MainActor
@Test func aFloatingWindowSaysSoInsteadOfDoingNothing() {
  let t = tiler([1, 2], focused: 1)
  t.world.toggleFloating(1)
  t.world.focused = 1
  #expect(t.execute(.accordion).hasPrefix("error: "))
}

@MainActor
@Test func swappingNeedsTwoTiledWindows() {
  let none = tiler([1, 2])
  #expect(none.execute(.swapWith(2)).hasPrefix("error: "))
  let t = tiler([1, 2], focused: 1)
  #expect(t.execute(.swapWith(1)).hasPrefix("error: "))
  #expect(t.execute(.swapWith(9)).hasPrefix("error: "))
  #expect(t.execute(.swapWith(2)) == "")
  #expect(t.world.monitors[0].lanes.map(\.windows) == [[2], [1]])
  #expect(t.world.focused == 1)
}

@MainActor
@Test func unknownWindowsAndTabsAreErrors() {
  let t = tiler([1], focused: 1)
  #expect(t.execute(.focusWindow(9)).hasPrefix("error: "))
  #expect(t.execute(.focusTab(9)).hasPrefix("error: "))
}

@MainActor
@Test func stateIsJSONWithTheWindows() throws {
  let t = tiler([1, 2], focused: 1)
  let text = t.execute(.state)
  let json = try JSONSerialization.jsonObject(
    with: Data(text.utf8))
  #expect(json is [String: Any])
}

@MainActor
@Test func closeAndReplaceNeedsATiledWindow() {
  #expect(tiler([1]).execute(.closeReplace).hasPrefix("error: "))
}

@MainActor
@Test func cmdTabGoesToThePickedWindow() {
  let t = tiler([1, 2], focused: 1)
  t.onCmdTab(.open(back: false))
  #expect(t.switcher.cards.count >= 2)
  #expect(t.switcher.pick == .window(1))
  t.onCmdTab(.step(back: false))
  #expect(t.switcher.pick == .window(2))
  t.onCmdTab(.release)
  #expect(t.switcher.cards.isEmpty)
  #expect(t.world.focused == 2)
}

@MainActor
@Test func cancellingCmdTabLeavesFocusWhereItWas() {
  let t = tiler([1, 2], focused: 1)
  t.onCmdTab(.open(back: false))
  t.onCmdTab(.step(back: false))
  t.onCmdTab(.cancel)
  #expect(t.switcher.cards.isEmpty)
  #expect(t.world.focused == 1)
}

@MainActor
@Test func cmdTabStaysOutOfTheWayWhilePaused() {
  let t = tiler([1], focused: 1)
  t.paused = true
  t.onCmdTab(.open(back: false))
  #expect(t.switcher.cards.isEmpty)
}

@Test func anAgeReadsAtAGlance() {
  #expect(Tiler.age(Date().addingTimeInterval(-12 * 60)) == "12m")
  #expect(Tiler.age(Date().addingTimeInterval(-3 * 3600)) == "3h")
  #expect(Tiler.age(Date().addingTimeInterval(-2 * 86400)) == "2d")
  #expect(Tiler.age(Date().addingTimeInterval(60)) == "0m")
}

@MainActor
@Test func thePickerMapShowsTheScreenAndItsWindows() {
  let t = tiler([1, 2], focused: 1)
  let map = t.pickerMap()
  #expect(map.monitors.count == 1)
  #expect(map.windows.count == 2)
}

@Test func aLongReplyCrossesTheSocketWhole() throws {
  var fds: [Int32] = [0, 0]
  #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
  defer { close(fds[0]) }
  let sent = String(repeating: "tess ", count: 20_000)
  let writer = fds[1]
  DispatchQueue.global().async {
    Socket.writeAll(writer, sent)
    close(writer)
  }
  #expect(Socket.readAll(fds[0]) == sent)
}

@Test func anAppCostsItsMemoryAndAMissingOneNothing() {
  let me = getpid()
  #expect((Usage.memory([me])[me] ?? 0) > 0)
  #expect((Usage.memory([999_999])[999_999] ?? 0) == 0)
}
