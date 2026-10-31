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

/// Runs a line as the CLI would, history included.
@MainActor
private func run(_ t: Tiler, _ line: String) throws -> String {
  t.run(try Command.parse(line), source: "test")
}

@MainActor
private func lanes(_ t: Tiler, _ m: Int = 0) -> [[WindowID]] {
  t.world.monitors[m].lanes.map(\.windows)
}

/// Two screens off the real ones, with 1 and 2 on the first and 3 on
/// the second.
@MainActor
private func twoScreens() -> Tiler {
  let t = tiler([1, 2], focused: 1)
  var second = Monitor(
    id: "B", frame: screen.offsetBy(dx: screen.width + 100, dy: 0))
  second.lanes = [Lane([3])]
  t.world.monitors.append(second)
  t.infos[3] = WinInfo(
    id: 3, pid: 1, frame: .zero, title: "", standard: true,
    fullscreenButton: true, nativeFullscreen: false)
  return t
}

@MainActor
@Test func undoAndRedoWalkTheHistory() throws {
  let t = tiler([1, 2], focused: 1)
  #expect(t.undo().hasPrefix("error: "))
  #expect(t.redo().hasPrefix("error: "))
  #expect(try run(t, "swap-with 2") == "")
  #expect(lanes(t) == [[2], [1]])
  #expect(t.undo() == "")
  #expect(lanes(t) == [[1], [2]])
  #expect(t.redo() == "")
  #expect(lanes(t) == [[2], [1]])
}

@MainActor
@Test func aNewChangeDropsWhatWasUndone() throws {
  let t = tiler([1, 2], focused: 1)
  _ = try run(t, "swap-with 2")
  #expect(t.undo() == "")
  _ = try run(t, "flip")
  #expect(t.redo().hasPrefix("error: "))
}

@MainActor
@Test func theSameChangeRepeatedIsOneStep() throws {
  let t = tiler([1, 2], focused: 1)
  let start = t.world.monitors[0].lanes
  _ = try run(t, "resize width 40")
  _ = try run(t, "resize width 40")
  #expect(t.history.count == 1)
  #expect(t.world.monitors[0].lanes != start)
  #expect(t.undo() == "")
  #expect(t.world.monitors[0].lanes == start)
}

@MainActor
@Test func theHistoryKeepsTheLastTenChanges() throws {
  let t = tiler([1, 2], focused: 1)
  for _ in 0..<6 {
    _ = try run(t, "flip")
    _ = try run(t, "accordion")
  }
  #expect(t.history.count == 10)
}

@MainActor
@Test func aChangeThatChangesNothingIsNotRemembered() throws {
  let t = tiler([1], focused: 1)
  _ = try run(t, "focus right")
  #expect(t.history.isEmpty)
}

@MainActor
@Test func focusAndMoveFollowTheLanes() throws {
  let t = tiler([1, 2, 3], focused: 1)
  #expect(try run(t, "focus right") == "")
  #expect(t.world.focused == 2)
  #expect(try run(t, "focus next") == "")
  #expect(t.world.focused == 3)
  #expect(try run(t, "focus prev") == "")
  #expect(t.world.focused == 2)
  #expect(try run(t, "move right") == "")
  #expect(lanes(t) == [[1], [3], [2]])
  #expect(t.world.focused == 2)
}

@MainActor
@Test func flipAndAccordionTurnOnAndOff() throws {
  let t = tiler([1, 2], focused: 1)
  _ = try run(t, "flip")
  #expect(t.world.monitors[0].rows)
  _ = try run(t, "flip")
  #expect(!t.world.monitors[0].rows)
  _ = try run(t, "accordion")
  #expect(t.world.monitors[0].lanes[0].accordion)
}

@MainActor
@Test func fullscreenIsAToggleAndTakesAFloatingWindowAlong() throws {
  let t = tiler([1, 2], focused: 1)
  _ = try run(t, "fullscreen")
  #expect(t.world.monitors[0].fullscreen == 1)
  _ = try run(t, "fullscreen")
  #expect(t.world.monitors[0].fullscreen == nil)
  t.world.toggleFloating(1)
  t.world.focused = 1
  _ = try run(t, "fullscreen")
  #expect(!t.world.floating.contains(1))
  #expect(t.world.monitors[0].fullscreen == 1)
}

@MainActor
@Test func floatingAWindowAndBack() throws {
  let t = tiler([1, 2], focused: 1)
  #expect(try run(t, "float") == "")
  #expect(t.world.floating.contains(1))
  #expect(try run(t, "float") == "")
  #expect(!t.world.floating.contains(1))
  #expect(t.world.contains(1))
}

@MainActor
@Test func screensAreReachedByNumberAndInTurn() throws {
  let t = twoScreens()
  #expect(try run(t, "focus-screen 2") == "")
  #expect(t.world.activeMonitor == 1)
  #expect(t.world.focused == 3)
  #expect(try run(t, "focus-screen next") == "")
  #expect(t.world.activeMonitor == 0)
}

@MainActor
@Test func aWindowMovesToAnotherScreen() throws {
  let t = twoScreens()
  #expect(try run(t, "move-to-screen 2") == "")
  #expect(lanes(t, 0) == [[2]])
  #expect(lanes(t, 1).flatMap { $0 }.sorted() == [1, 3])
}

@MainActor
@Test func windowsOnAnotherSpaceWearNoLetter() {
  let t = tiler([1, 2], focused: 1)
  t.offSpace.insert(2)
  #expect(t.labeledWindows == [1])
}

@MainActor
@Test func cmdTabGoesToALetterAtOnce() throws {
  let t = tiler([1, 2], focused: 1)
  t.onCmdTab(.open(back: false))
  let label = try #require(
    t.switcher.cards.first { $0.target == .window(2) }?.label)
  let code = try #require(Hotkeys.codes[String(label)])
  t.onCmdTab(.letter(UInt16(code)))
  #expect(t.switcher.cards.isEmpty)
  #expect(t.world.focused == 2)
}

@MainActor
@Test func aLetterNoCardWearsDoesNothing() throws {
  let t = tiler([1], focused: 1)
  t.onCmdTab(.open(back: false))
  t.onCmdTab(.letter(UInt16.max))
  #expect(!t.switcher.cards.isEmpty)
  t.onCmdTab(.cancel)
}

@MainActor
@Test func backwardsCmdTabStartsAtTheEnd() {
  let t = tiler([1, 2], focused: 1)
  t.onCmdTab(.open(back: true))
  #expect(t.switcher.pick == t.switcher.cards.last?.target)
  t.onCmdTab(.cancel)
}

@MainActor
@Test func aDropSaysWhereTheWindowGoes() {
  let t = tiler([1, 2], focused: 1)
  let name = t.appName(2)
  #expect(t.caption(.stay) == L("Back in place"))
  #expect(t.caption(.screen(1)) == L("Screen 2"))
  #expect(t.caption(.swap(2)) == L("Swap with \(name)"))
  #expect(t.caption(.lane(2, after: true)) == L("Right of \(name)"))
  #expect(t.caption(.lane(2, after: false)) == L("Left of \(name)"))
  #expect(t.caption(.stack(2, after: true)) == L("Below \(name)"))
  t.world.monitors[0].rows = true
  #expect(t.caption(.lane(2, after: true)) == L("Below \(name)"))
  #expect(t.caption(.stack(2, after: false)) == L("Left of \(name)"))
}

@MainActor
@Test func aSpotReadsAsAPlace() {
  let t = tiler([1], focused: 1)
  #expect(t.describe(.here) == L("here"))
  #expect(t.describe(.monitor(1)) == L("on screen 2"))
  #expect(t.describe(.float) == L("floating"))
}

@MainActor
@Test func aWindowForgottenLeavesTheLayout() {
  let t = tiler([1, 2], focused: 1)
  t.forget(1)
  #expect(t.infos[1] == nil)
  #expect(!t.world.contains(1))
}

@MainActor
@Test func aNewWindowIsAdoptedWhereItIs() {
  let t = tiler([1], focused: 1)
  let info = WinInfo(
    id: 2, pid: 1,
    frame: CGRect(
      x: screen.midX, y: screen.minY, width: 900, height: 1000),
    title: "", standard: true, fullscreenButton: true,
    nativeFullscreen: false)
  t.infos[2] = info
  t.adopt([info])
  #expect(t.world.contains(2))
  #expect(lanes(t).flatMap { $0 }.sorted() == [1, 2])
}

private func item(_ kind: Picker.Kind) -> Picker.Item {
  Picker.Item(
    kind: kind, title: "", detail: "", icon: nil, search: "")
}

@MainActor
@Test func aPickedPlaceIsOneStepOfTheHistory() {
  let t = tiler([1, 2, 3], focused: 1)
  let start = lanes(t)
  t.use(3, .place(.replace(1)))
  #expect(lanes(t) != start)
  #expect(t.history.count == 1)
  #expect(t.undo() == "")
  #expect(lanes(t) == start)
}

@MainActor
@Test func aJumpOnlyMovesFocus() {
  let t = tiler([1, 2], focused: 1)
  t.use(2, .jump)
  #expect(t.world.focused == 2)
  #expect(t.history.isEmpty)
  #expect(lanes(t) == [[1], [2]])
}

@MainActor
@Test func aWindowItsAppHasNotListedWaitsForItsPlace() {
  let t = tiler([1], focused: 1)
  // A pid nobody has, so no real app comes forward.
  t.unseen[9] = 999_999
  t.use(9, .place(.here))
  #expect(t.placing?.pid == 999_999)
  #expect(t.placing?.spot == .here)
  #expect(!t.world.contains(9))
}

@MainActor
@Test func pickingAWindowJumpsThereAndACommandRuns() {
  let t = tiler([1, 2], focused: 1)
  t.picked(item(.window(2)), .jump)
  #expect(t.world.focused == 2)
  t.picked(item(.command([.swapWith(1)])), .jump)
  #expect(lanes(t) == [[2], [1]])
}

@MainActor
@Test func aReportOfMacOSMovesFocus() {
  let t = tiler([1, 2], focused: 1)
  t.syncFocus(2)
  #expect(t.world.focused == 2)
  t.syncFocus(9)
  #expect(t.world.focused == 2)
}

@MainActor
@Test func macOSIsOverruledOnceThenBelieved() {
  let t = tiler([1, 2], focused: 1)
  t.focus(1)
  t.syncFocus(2)
  #expect(t.world.focused == 1)
  #expect(t.intent?.reasserted == true)
  t.syncFocus(2)
  #expect(t.world.focused == 2)
}

@MainActor
@Test func aFloatingWindowsScreenBecomesTheActiveOne() {
  let t = twoScreens()
  t.world.toggleFloating(3)
  t.infos[3]?.frame = t.world.monitors[1].frame.insetBy(
    dx: 50, dy: 50)
  t.syncFocus(3)
  #expect(t.world.activeMonitor == 1)
}

@MainActor
@Test func nothingTakesFocusWhileThePickerIsOpen() {
  let t = tiler([1, 2], focused: 1)
  t.picking = true
  t.focus(2)
  #expect(t.intent == nil)
}

@MainActor
@Test func rebuildingReadsTheLayoutOffTheScreen() {
  let t = tiler([1, 2], focused: 1)
  let half = CGSize(width: 800, height: 1000)
  t.infos[1]?.frame = CGRect(
    origin: CGPoint(x: screen.midX, y: screen.minY), size: half)
  t.infos[2]?.frame = CGRect(origin: screen.origin, size: half)
  t.writes[1] = (.zero, 1)
  t.rebuild()
  #expect(lanes(t) == [[2], [1]])
  #expect(t.writes[1] == nil)
}

@MainActor
@Test func theMapDrawsFullscreenAndRibbonsFlat() {
  let t = tiler([1, 2, 3, 4, 5], focused: 1)
  let flat = t.pickerMap().windows.map(\.frame)
  t.world.monitors[0].fullscreen = 1
  #expect(t.pickerMap().windows.map(\.frame) == flat)
  t.world.monitors[0].fullscreen = nil
  t.world.monitors[0].ribbon = true
  #expect(t.pickerMap().windows.map(\.frame) == flat)
}

@MainActor
@Test func anAccordionIsDrawnAsRowsOnTheMap() {
  let t = tiler([1], focused: 1)
  t.infos[2] = t.infos[1]
  t.world.monitors[0].lanes = [Lane([1, 2])]
  t.world.monitors[0].lanes[0].accordion = true
  let rows = t.pickerMap().windows.map(\.frame)
  #expect(rows.count == 2)
  #expect(rows[0].height == rows[1].height)
  #expect(rows[1].minY == rows[0].maxY)
}

@MainActor
@Test func theMapWarnsOnlyAboutWindowsThatKeptTheirSize() {
  let t = tiler([1, 2, 3], focused: 1)
  #expect(t.pickerMap(for: item(.window(3))).hereWarning == nil)
  // Window 2 keeps 1500 wide, more than any place here gives it.
  t.refused = [2]
  t.writes[2] = (CGRect(x: 0, y: 0, width: 300, height: 900), 3)
  t.infos[2]?.frame = CGRect(x: 0, y: 0, width: 1500, height: 900)
  let map = t.pickerMap(for: item(.window(3)))
  // Swapping 3 with 2 moves 2; swapping it with 1 leaves 2 alone.
  #expect(map.replaceWarnings[2] != nil)
  #expect(map.replaceWarnings[1] == nil)
}

@MainActor
@Test func thePickerOffersTessCommandsOnceSomethingIsTyped() {
  let t = tiler([1], focused: 1)
  let commands = t.pickerItems().filter {
    if case .command = $0.kind { return $0.quiet }
    return false
  }
  #expect(!commands.isEmpty)
  #expect(commands.allSatisfy { !$0.title.isEmpty })
}

@MainActor
@Test func aWindowOnItsWayHasNoOutline() {
  let t = tiler([1], focused: 1)
  let here = CGRect(x: 0, y: 0, width: 400, height: 300)
  let there = here.offsetBy(dx: 300, dy: 0)
  t.infos[1]?.frame = here
  #expect(!t.inTransit(1, at: here))
  t.assumed.insert(1)
  #expect(t.inTransit(1, at: here))
  t.assumed = []
  t.landing[1] = Date().addingTimeInterval(1)
  #expect(t.inTransit(1, at: there))
  #expect(!t.inTransit(1, at: here))
  t.landing[1] = Date().addingTimeInterval(-1)
  #expect(!t.inTransit(1, at: there))
}

@MainActor
@Test func windowsUnderAnothersFullscreenAreNotShown() {
  let t = tiler([1, 2], focused: 1)
  #expect(t.shownWindows == [1, 2])
  t.world.monitors[0].fullscreen = 2
  #expect(t.shownWindows == [2])
}

@MainActor
@Test func onlyTheFocusedWindowGetsAnOutlineUntilLettersAreUp() {
  let t = tiler([1, 2], focused: 1)
  t.labels = [1: "a", 2: "b"]
  let left = CGRect(x: 0, y: 0, width: 400, height: 300)
  let stack = [
    (id: WindowID(1), frame: left),
    (id: WindowID(2), frame: left.offsetBy(dx: 500, dy: 0))
  ]
  let focused = t.decorationWindows(in: stack, focused: 1, all: false)
  #expect(focused.count == 1)
  #expect(focused.first?.focused == true)
  #expect(focused.first?.label == nil)
  let all = t.decorationWindows(in: stack, focused: 1, all: true)
  #expect(all.count == 2)
  #expect(Set(all.compactMap(\.label)) == ["a", "b"])
}

@MainActor
@Test func aWindowUnderAnotherIsNotVisible() {
  let t = tiler([1, 2], focused: 1)
  let r = CGRect(x: 0, y: 0, width: 400, height: 300)
  #expect(
    t.visibleWindows([
      (id: WindowID(2), frame: r), (id: WindowID(1), frame: r)
    ]) == [2])
}

@MainActor
@Test func theDebugMapIsAnImageOfTheLayout() throws {
  let t = tiler([1, 2, 3], focused: 1)
  t.world.monitors[0].lanes[1].accordion = true
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("tess-map-\(UUID()).png").path
  defer { try? FileManager.default.removeItem(atPath: path) }
  #expect(t.execute(.debugMap(path)) == path)
  let image = try #require(NSImage(contentsOfFile: path))
  #expect(image.size.width > 0)
  #expect(
    t.execute(.debugMap("/no/such/folder/map.png"))
      .hasPrefix("error: "))
}

@MainActor
@Test func cmdTabPrefersWhatWasRecentlyInFront() throws {
  let t = tiler([1], focused: 1)
  let all = t.windowlessApps(besides: [])
  #expect(!all.contains { $0.processIdentifier == getpid() })
  let app = try #require(all.last)
  t.recentApps = [app.processIdentifier]
  #expect(
    t.windowlessApps(besides: []).first?.processIdentifier
      == app.processIdentifier)
  #expect(
    !t.windowlessApps(besides: [app.processIdentifier]).contains {
      $0.processIdentifier == app.processIdentifier
    })
}

@MainActor
@Test func aShortTitleWinsOverTheTitleSplitUp() {
  let t = tiler([1], focused: 1)
  #expect(t.shortTitle("Inbox", app: "Mail") == "Inbox")
  t.shortTitles["Inbox"] = "Mail in"
  #expect(t.shortTitle("Inbox", app: "Mail") == "Mail in")
}

@MainActor
@Test func theTreeSaysWhatIsSpecialAboutAWindow() {
  let t = tiler([1, 2, 3], focused: 1)
  t.world.monitors[0].lanes[1].accordion = true
  t.world.monitors[0].fullscreen = 1
  t.refused = [2]
  t.world.toggleFloating(3)
  t.world.focused = 1
  let tree = t.tree()
  #expect(tree.contains("<- focused"))
  #expect(tree.contains(" fullscreen"))
  #expect(tree.contains("(keeps its own size)"))
  #expect(tree.contains("accordion"))
  #expect(tree.contains("floating"))
  t.world.monitors[0].rows = true
  #expect(t.tree().contains("row 1"))
}

@MainActor
@Test func balancingUndoesAResize() {
  let t = tiler([1, 2], focused: 1)
  let even = t.world.frames(
    inner: t.config.inner, outer: t.config.outer)
  _ = t.run([.resize(.width, 100)], source: "test")
  #expect(
    t.world.frames(inner: t.config.inner, outer: t.config.outer)
      != even)
  _ = t.run([.balance], source: "test")
  #expect(
    t.world.frames(inner: t.config.inner, outer: t.config.outer)
      == even)
}

@MainActor
@Test func growingTakesRoomFromTheNeighbors() {
  let t = tiler([1, 2], focused: 1)
  let was = t.world.frames(
    inner: t.config.inner, outer: t.config.outer)
  _ = t.run([.grow(100)], source: "test")
  let now = t.world.frames(
    inner: t.config.inner, outer: t.config.outer)
  #expect(now[1, default: .zero].width > was[1, default: .zero].width)
  #expect(now[2, default: .zero].width < was[2, default: .zero].width)
}
