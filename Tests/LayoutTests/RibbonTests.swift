import CoreGraphics
import Foundation
import Testing
@testable import Layout

private let wide = (
  id: "A", frame: CGRect(x: 0, y: 40, width: 1800, height: 1129)
)

/// A screen 1800 by 1129 as a ribbon holding `lanes`.
private func ribbon(_ lanes: [[WindowID]], focused: WindowID? = nil)
  -> World
{
  var w = World()
  w.setMonitors([wide])
  w.monitors[0].lanes = lanes.map { Lane($0) }
  w.monitors[0].ribbon = true
  w.focused = focused
  return w
}

private let inner = 10.0, outer = 10.0

private func frames(_ w: World) -> [WindowID: CGRect] {
  w.frames(inner: inner, outer: outer)
}

@Test func columnsKeepTheirWidthHoweverManyThereAre() {
  let two = frames(ribbon([[1], [2]], focused: 1))
  var six = ribbon([[1], [2], [3], [4], [5], [6]], focused: 1)
  six.reveal(inner: inner, outer: outer)
  let many = frames(six)
  #expect(many[1] == two[1])
  #expect(many[2] == two[2])
  // Two lanes of half the screen fill it exactly, gaps included.
  let area = six.tileArea(0, inner: inner, outer: outer)
  #expect(two[1]?.minX == area.minX)
  #expect(two[2]?.maxX == area.maxX)
}

@Test func aLoneLaneFillsTheScreen() {
  let w = ribbon([[1]], focused: 1)
  #expect(frames(w)[1] == w.tileArea(0, inner: inner, outer: outer))
}

@Test func windowsOutOfViewParkAsTabsTheirOwnSize() {
  var w = ribbon([[1], [2], [3], [4]], focused: 1)
  w.reveal(inner: inner, outer: outer)
  let f = frames(w)
  #expect(w.parked(inner: inner, outer: outer) == [3, 4])
  // Their title bars along the bottom, side by side, and the same
  // size as when tiled.
  for id in [WindowID(3), 4] {
    let tray: CGFloat = wide.frame.maxY - World.trayDepth
    #expect(f[id]!.minY == tray)
    #expect(f[id]?.size == f[1]?.size)
  }
  #expect(f[3]!.minX < f[4]!.minX)
  #expect(f[4]!.maxX <= wide.frame.maxX)
  // Tiled windows stop above the strip, so the tabs never cover them.
  #expect(f[1]!.maxY <= f[3]!.minY)
}

@Test func tilingDoesNotShiftWhenNothingIsParked() {
  var few = ribbon([[1], [2]], focused: 1)
  var many = ribbon([[1], [2], [3], [4]], focused: 1)
  few.reveal(inner: inner, outer: outer)
  many.reveal(inner: inner, outer: outer)
  #expect(frames(few)[1] == frames(many)[1])
}

@Test func focusScrollsOnlyAsFarAsItTakes() {
  var w = ribbon([[1], [2], [3], [4]], focused: 1)
  func step(to id: WindowID) -> Bool {
    w.focused = id
    return w.reveal(inner: inner, outer: outer)
  }
  #expect(!step(to: 1))
  #expect(w.monitors[0].scroll == 0)
  #expect(!step(to: 2))  // already in view
  #expect(step(to: 3))
  #expect(w.parked(inner: inner, outer: outer) == [1, 4])
  w.focused = 4
  w.reveal(inner: inner, outer: outer)
  #expect(w.parked(inner: inner, outer: outer) == [1, 2])

  // Back left: 3 comes in on the left, and 4 stays.
  #expect(!step(to: 3))
  w.focused = 2
  w.reveal(inner: inner, outer: outer)
  #expect(w.parked(inner: inner, outer: outer) == [1, 4])
  #expect(
    frames(w)[2]?.minX
      == w.tileArea(0, inner: inner, outer: outer).minX)
}

@Test func aFocusedWindowIsNeverParked() {
  var w = ribbon([[1, 2], [3], [4, 5], [6], [7]], focused: 1)
  for id in [WindowID(7), 1, 5, 3, 6, 2, 4] {
    w.focused = id
    w.reveal(inner: inner, outer: outer)
    #expect(
      !w.parked(inner: inner, outer: outer).contains(id), "\(id)")
    let area = w.tileArea(0, inner: inner, outer: outer)
    #expect(
      area.contains(frames(w)[id]!.insetBy(dx: 1, dy: 1)), "\(id)")
  }
}

@Test func aColumnWiderThanTheScreenStillShows() {
  var w = ribbon([[1], [2], [3]], focused: 3)
  w.monitors[0].lanes[2].span = 1
  w.reveal(inner: inner, outer: outer)
  #expect(
    frames(w)[3]?.minX
      == w.tileArea(0, inner: inner, outer: outer).minX)
  #expect(w.parked(inner: inner, outer: outer) == [1, 2])
}

@Test func closingAWindowPullsTheRibbonBack() {
  var w = ribbon([[1], [2], [3], [4]], focused: 4)
  w.reveal(inner: inner, outer: outer)
  #expect(w.monitors[0].scroll > 0)
  w.remove(4)
  w.remove(3)
  w.reveal(inner: inner, outer: outer)
  #expect(w.monitors[0].scroll == 0)
  #expect(w.parked(inner: inner, outer: outer).isEmpty)
}

@Test func anOpeningWindowTakesNoRoomFromTheOthers() {
  var w = ribbon([[1], [2]], focused: 2)
  w.reveal(inner: inner, outer: outer)
  let before = frames(w)
  w.insert(3)
  w.reveal(inner: inner, outer: outer)
  let after = frames(w)
  #expect(after[3]?.size == before[2]?.size)
  #expect(after[2]?.size == before[2]?.size)
  #expect(w.parked(inner: inner, outer: outer) == [1])
}

@Test func growingAColumnLeavesTheOthersAlone() {
  var w = ribbon([[1], [2], [3]], focused: 1)
  w.reveal(inner: inner, outer: outer)
  let before = frames(w)
  w.grow(by: 100)
  w.reveal(inner: inner, outer: outer)
  let after = frames(w)
  #expect(abs(after[1]!.width - before[1]!.width - 100) <= 2)
  #expect(after[2]!.width == before[2]!.width)
  // Limits: never past the screen, never to nothing.
  for _ in 0..<40 { w.grow(by: 100) }
  #expect(w.monitors[0].lanes[0].span == 1)
  for _ in 0..<40 { w.grow(by: -100) }
  #expect(w.monitors[0].lanes[0].span == 0.1)
  w.balance()
  #expect(w.monitors[0].lanes[0].span == 0.5)
}

@Test func growOnALoneLaneGoesAlongItsStack() {
  var w = ribbon([[1, 2]], focused: 1)
  w.grow(by: 100)
  #expect(frames(w)[1]!.height > frames(w)[2]!.height)
}

@Test func moveSwapsAcrossTheRibbonAndFocusFollows() {
  var w = ribbon([[1], [2], [3]], focused: 2)
  w.reveal(inner: inner, outer: outer)
  w.move(.right)
  w.reveal(inner: inner, outer: outer)
  #expect(w.monitors[0].lanes.map(\.windows) == [[1], [3], [2]])
  #expect(!w.parked(inner: inner, outer: outer).contains(2))
}

@Test func minimumsWidenAColumnWithoutTouchingTheOthers() {
  var w = ribbon([[1], [2], [3]], focused: 1)
  w.reveal(inner: inner, outer: outer)
  let before = frames(w)
  w.respect(
    [1: CGSize(width: 1200, height: 0)], inner: inner, outer: outer)
  let after = frames(w)
  #expect(after[1]?.width == 1200)
  #expect(after[2]?.size == before[2]?.size)
  // The whole screen is as far as it goes.
  w.respect(
    [1: CGSize(width: 5000, height: 0)], inner: inner, outer: outer)
  #expect(w.monitors[0].lanes[0].span == 1)

  var stack = ribbon([[1, 2], [3]], focused: 1)
  stack.respect(
    [1: CGSize(width: 0, height: 700)], inner: inner, outer: outer)
  #expect(frames(stack)[1]?.height == 700)
}

@Test func offAgainTheScreenTilesAsBefore() {
  var w = ribbon([[1], [2], [3], [4]], focused: 4)
  w.reveal(inner: inner, outer: outer)
  w.toggleRibbon()
  #expect(!w.monitors[0].ribbon)
  #expect(w.monitors[0].scroll == 0)
  #expect(w.parked(inner: inner, outer: outer).isEmpty)
  var plain = World()
  plain.setMonitors([wide])
  plain.monitors[0].lanes = (1...4).map { Lane([WindowID($0)]) }
  #expect(frames(w) == plain.frames(inner: inner, outer: outer))
}

@Test func tessFullscreenStillFillsTheScreen() {
  var w = ribbon([[1], [2], [3]], focused: 3)
  w.reveal(inner: inner, outer: outer)
  w.toggleFullscreen()
  #expect(frames(w)[3] == wide.frame)
}

@Test func accordionsAndStacksWorkInARibbon() {
  var w = ribbon([[1, 2], [3], [4]], focused: 3)
  w.monitors[0].lanes[0].accordion = true
  w.reveal(inner: inner, outer: outer)
  let f = frames(w)
  #expect(f[1] == f[2])
  var stacked = ribbon([[1, 2], [3]], focused: 1)
  stacked.reveal(inner: inner, outer: outer)
  let s = frames(stacked)
  #expect(s[1]!.maxY < s[2]!.minY)
  #expect(s[1]!.width == s[2]!.width)
  let tray: CGFloat = wide.frame.maxY - World.trayDepth
  #expect(s[2]!.maxY <= tray)
}

@Test func aPortraitScreenRunsDownwards() {
  var w = World()
  w.setMonitors([
    (id: "T", frame: CGRect(x: 0, y: 40, width: 800, height: 1400))
  ])
  w.monitors[0].lanes = [[1], [2], [3]].map { Lane($0) }
  w.monitors[0].ribbon = true
  w.focused = 3
  w.reveal(inner: inner, outer: outer)
  #expect(w.monitors[0].rows)
  #expect(w.parked(inner: inner, outer: outer) == [1])
  let f = frames(w)
  #expect(f[2]!.maxY <= f[3]!.minY)
  #expect(
    f[2]!.width == w.tileArea(0, inner: inner, outer: outer).width)
}

// MARK: Several screens

private let west = (
  id: "L", frame: CGRect(x: 0, y: 40, width: 1800, height: 1129)
)
private let east = (
  id: "R", frame: CGRect(x: 1800, y: 40, width: 1920, height: 1040)
)
private let south = (
  id: "B", frame: CGRect(x: 0, y: 1169, width: 1800, height: 1000)
)

@Test func eachScreenHasItsOwnRibbon() {
  var w = World()
  w.setMonitors([west, east])
  w.monitors[0].lanes = [[1], [2], [3]].map { Lane($0) }
  w.monitors[1].lanes = [[4], [5], [6]].map { Lane($0) }
  w.monitors[0].ribbon = true
  w.monitors[1].ribbon = true
  w.focused = 3
  w.reveal(inner: inner, outer: outer)
  #expect(w.parked(inner: inner, outer: outer) == [1, 6])
  w.focused = 6
  w.reveal(inner: inner, outer: outer)
  // The first screen stays scrolled where it was.
  #expect(w.parked(inner: inner, outer: outer) == [1, 4])
  let s = w.strips(inner: inner, outer: outer)
  #expect(s.map(\.monitor) == [0, 1])
  #expect(s[0].shown == [false, true, true])
  #expect(s[1].shown == [false, true, true])
}

@Test func parkedWindowsNeverLandOnTheScreenBeside() {
  var w = World()
  w.setMonitors([west, east])
  w.monitors[0].lanes = (1...7).map { Lane([WindowID($0)]) }
  w.monitors[0].ribbon = true
  w.focused = 1
  w.reveal(inner: inner, outer: outer)
  #expect(w.parkEdge(0) == .bottom)
  for (id, f) in frames(w) {
    #expect(f.maxX <= west.frame.maxX, "\(id)")
  }
}

@Test func aScreenBelowMovesTheStripToASide() {
  var w = World()
  w.setMonitors([west, south])
  #expect(w.parkEdge(0) == .right)
  #expect(w.parkEdge(1) == .bottom)
  w.monitors[0].lanes = [[1], [2], [3]].map { Lane($0) }
  w.monitors[0].ribbon = true
  w.focused = 1
  w.reveal(inner: inner, outer: outer)
  let f = frames(w)
  let side: CGFloat = west.frame.maxX - World.sideDepth
  #expect(f[3]!.minX == side)
  #expect(f[3]!.maxY <= west.frame.maxY)
  #expect(f[2]!.maxX <= side)
}

@Test func withScreensAllRoundTheLeftSideOrBottomIsUsed() {
  var w = World()
  w.setMonitors([west, east, south])
  #expect(w.parkEdge(0) == .left)
  var boxed = World()
  boxed.setMonitors([
    (
      id: "X",
      frame: CGRect(x: -1800, y: 40, width: 1800, height: 1129)
    ), west, east, south
  ])
  #expect(boxed.parkEdge(1) == .bottom)
}

@Test func aScreenLeavingHandsItsColumnsToTheRibbonThatStays() {
  var w = World()
  w.setMonitors([west, east])
  w.monitors[0].lanes = [[1], [2]].map { Lane($0) }
  w.monitors[1].lanes = [[3], [4]].map { Lane($0) }
  w.monitors[0].ribbon = true
  w.focused = 1
  w.setMonitors([west])
  w.reveal(inner: inner, outer: outer)
  #expect(w.monitors[0].windows == [1, 2, 3, 4])
  #expect(w.parked(inner: inner, outer: outer) == [3, 4])
  w.setMonitors([west, east])
  #expect(w.monitors[1].windows == [3, 4])
}

@Test func nothingIsLostWhenTessStartsOverOnAParkedRibbon() {
  var w = ribbon([[1], [2], [3], [4]], focused: 2)
  w.reveal(inner: inner, outer: outer)
  let seen = frames(w).map { (id: $0.key, frame: $0.value) }.sorted {
    $0.id < $1.id
  }

  var again = World()
  again.setMonitors([wide])
  again.monitors[0].ribbon = true
  again.rebuild(seen, inner: inner, outer: outer)
  #expect(Set(again.tiled) == [1, 2, 3, 4])
  #expect(again.monitors[0].windows.prefix(2) == [1, 2])
  // Parked tabs come back in the order they stood.
  #expect(again.monitors[0].windows.suffix(2) == [3, 4])
  again.focused = 1
  again.reveal(inner: inner, outer: outer)
  #expect(again.parked(inner: inner, outer: outer) == [3, 4])
  #expect(frames(again)[1]?.size == frames(w)[1]?.size)
}

@Test func aRetileKeepsARibbonInOrder() {
  var w = ribbon([[1], [2], [3], [4]], focused: 3)
  w.monitors[0].lanes[3].span = 0.7
  w.reveal(inner: inner, outer: outer)
  let seen = frames(w).map { (id: $0.key, frame: $0.value) }
  let scroll = w.monitors[0].scroll
  w.rebuild(seen, inner: inner, outer: outer)
  #expect(w.monitors[0].lanes.map(\.windows) == [[1], [2], [3], [4]])
  #expect(w.monitors[0].scroll == scroll)
  #expect(abs(w.monitors[0].lanes[3].span - 0.7) < 0.01)
}

@Test func windowsParkedOnTwoRibbonsStayOnTheirOwn() {
  var w = World()
  w.setMonitors([west, east])
  w.monitors[0].lanes = [[1], [2], [3]].map { Lane($0) }
  w.monitors[1].lanes = [[4], [5], [6]].map { Lane($0) }
  w.setRibbon(0, true)
  w.setRibbon(1, true)
  w.monitors[0].lanes.indices.forEach {
    w.monitors[0].lanes[$0].span = 0.5
  }
  w.monitors[1].lanes.indices.forEach {
    w.monitors[1].lanes[$0].span = 0.5
  }
  w.focused = 1
  w.reveal(inner: inner, outer: outer)
  let seen = frames(w).map { (id: $0.key, frame: $0.value) }
  var again = World()
  again.ribbons = true
  again.setMonitors([west, east])
  again.rebuild(seen, inner: inner, outer: outer)
  #expect(Set(again.monitors[0].windows) == [1, 2, 3])
  #expect(Set(again.monitors[1].windows) == [4, 5, 6])
}

@Test func turningItOnMovesNoColumn() {
  var w = World()
  w.setMonitors([wide])
  w.monitors[0].lanes = [
    Lane([1], size: 3), Lane([2], size: 1), Lane([3], size: 1)
  ]
  let before = frames(w)
  w.toggleRibbon()
  let after = frames(w)
  #expect(w.parked(inner: inner, outer: outer).isEmpty)
  for id in [WindowID(1), 2, 3] {
    #expect(abs(after[id]!.minX - before[id]!.minX) <= inner)
    #expect(abs(after[id]!.width - before[id]!.width) <= inner)
  }
  // A screen with one lane stays ready for a second beside it.
  var one = ribbon([[1]], focused: 1)
  one.toggleRibbon()
  one.toggleRibbon()
  #expect(one.monitors[0].lanes[0].span == 0.5)
}

@Test func aNewScreenFollowsTheConfig() {
  var w = World()
  w.ribbons = true
  w.setMonitors([west])
  w.setMonitors([west, east])
  #expect(w.monitors.map(\.ribbon) == [true, true])
  w.monitors[0].ribbon = false
  w.setMonitors([west, east])
  #expect(!w.monitors[0].ribbon)
}

@Test func tabsOnTheStripShowApart() {
  var w = ribbon((1...5).map { [WindowID($0)] }, focused: 1)
  w.reveal(inner: inner, outer: outer)
  let f = frames(w)
  let xs = [WindowID(3), 4, 5].map { f[$0]!.minX }
  #expect(Set(xs).count == 3)
  #expect(xs == xs.sorted())
  #expect(f[5]!.maxX <= wide.frame.maxX)
}

@Test func onASideWindowsFanOutUnlessAScreenIsThere() {
  let tall = CGRect(x: 0, y: 40, width: 1800, height: 1129)
  var free = World()
  free.setMonitors([
    (id: "T", frame: tall),
    (
      id: "L",
      frame: CGRect(x: 300, y: 1169, width: 1200, height: 800)
    )
  ])
  free.monitors[0].lanes = (1...4).map { Lane([WindowID($0)]) }
  free.monitors[0].ribbon = true
  free.focused = 1
  free.reveal(inner: inner, outer: outer)
  #expect(free.parkEdge(0) == .right)
  let f = frames(free)
  #expect(f[3]!.minY < f[4]!.minY)

  var aligned = World()
  aligned.setMonitors([
    (id: "T", frame: tall),
    (id: "L", frame: CGRect(x: 0, y: 1169, width: 1800, height: 800))
  ])
  aligned.monitors[0].lanes = (1...4).map { Lane([WindowID($0)]) }
  aligned.monitors[0].ribbon = true
  aligned.focused = 1
  aligned.reveal(inner: inner, outer: outer)
  for (_, r) in frames(aligned) { #expect(r.maxY <= tall.maxY) }
}

@Test func aRibbonDrawsItsColumnsToScale() {
  var w = ribbon([[1, 2], [3], [4]], focused: 1)
  w.monitors[0].lanes[2].span = 0.25
  w.reveal(inner: inner, outer: outer)
  let s = w.strips(inner: inner, outer: outer)
  #expect(s.count == 1)
  #expect(s[0].lanes == [[1, 2], [3], [4]])
  #expect(s[0].shown == [true, true, false])
  #expect(s[0].lengths[2] < s[0].lengths[0])
  w.toggleRibbon()
  #expect(w.strips(inner: inner, outer: outer).isEmpty)
}

@Test func aWindowTakesItsWidthAlongWhenItSwaps() {
  var w = ribbon([[1], [2], [3]], focused: 1)
  w.monitors[0].lanes[0].span = 0.6
  let width = { (w: World) in frames(w)[1]!.width }
  let before = width(w)
  w.move(.right)
  #expect(w.monitors[0].lanes.map(\.windows) == [[2], [1], [3]])
  #expect(width(w) == before)
  #expect(w.monitors[0].lanes.map(\.span) == [0.5, 0.6, 0.5])
  // Sharing a column it is not its own, and the column stays as it
  // is.
  var stacked = ribbon([[1, 2], [3]], focused: 1)
  stacked.monitors[0].lanes[0].span = 0.6
  stacked.swap(1, 3)
  #expect(stacked.monitors[0].lanes.map(\.span) == [0.6, 0.5])
}

@Test func aColumnCutByTheEdgeStaysOutWhenNothingLiesPastIt() {
  var w = ribbon([[1], [2], [3]], focused: 1)
  w.monitors[0].lanes[0].span = 0.6
  w.reveal(inner: inner, outer: outer)
  #expect(w.parked(inner: inner, outer: outer) == [3])
  var f = frames(w)
  let right: CGFloat = wide.frame.maxX
  let gap: CGFloat = f[2]!.minX - f[1]!.maxX
  #expect(abs(gap - 10) <= 1)
  #expect(f[2]!.maxX > right)
  #expect(
    w.strips(inner: inner, outer: outer)[0].shown == [
      true, true, false
    ])

  // Focus brings it in whole, cutting the one on the other side.
  w.focused = 2
  w.reveal(inner: inner, outer: outer)
  f = frames(w)
  #expect(
    f[2]!.maxX == w.tileArea(0, inner: inner, outer: outer).maxX)
  #expect(f[1]!.minX < wide.frame.minX)
  #expect(w.parked(inner: inner, outer: outer) == [3])
}

@Test func aColumnThatWouldReachAnotherScreenOrShowASliverParks() {
  var beside = World()
  beside.setMonitors([west, east])
  beside.monitors[0].lanes = [[1], [2], [3]].map { Lane($0) }
  beside.monitors[0].ribbon = true
  beside.monitors[0].lanes[0].span = 0.6
  beside.focused = 1
  beside.reveal(inner: inner, outer: outer)
  #expect(beside.parked(inner: inner, outer: outer) == [2, 3])
  for (id, f) in frames(beside) {
    #expect(f.maxX <= west.frame.maxX, "\(id)")
  }

  var sliver = ribbon([[1], [2]], focused: 1)
  sliver.monitors[0].lanes[0].span = 0.95
  sliver.reveal(inner: inner, outer: outer)
  #expect(sliver.parked(inner: inner, outer: outer) == [2])

  // On a side strip's side, it would lie over the strip.
  var stacked = World()
  stacked.setMonitors([west, south])
  stacked.monitors[0].lanes = [[1], [2], [3]].map { Lane($0) }
  stacked.monitors[0].ribbon = true
  stacked.monitors[0].lanes[0].span = 0.6
  stacked.focused = 1
  stacked.reveal(inner: inner, outer: outer)
  #expect(stacked.parked(inner: inner, outer: outer) == [2, 3])

  // Going down a portrait screen, the bottom is the strip.
  var tall = World()
  tall.setMonitors([
    (id: "T", frame: CGRect(x: 0, y: 40, width: 800, height: 1400))
  ])
  tall.monitors[0].lanes = [[1], [2], [3]].map { Lane($0) }
  tall.monitors[0].ribbon = true
  tall.monitors[0].lanes[0].span = 0.6
  tall.focused = 1
  tall.reveal(inner: inner, outer: outer)
  #expect(tall.parked(inner: inner, outer: outer) == [2, 3])
}

@Test func aLoneColumnKeepsNoWidthNobodyCouldSee() {
  var w = ribbon([[1]], focused: 1)
  for _ in 0..<20 { w.resize(.width, by: -100) }
  #expect(w.monitors[0].lanes[0].span == 0.5)
  w.insert(2)
  #expect(frames(w)[1]!.width == frames(w)[2]!.width)

  // Nor does one left from an earlier life as a ribbon.
  var again = ribbon([[1], [2]], focused: 1)
  again.monitors[0].lanes[0].span = 0.2
  again.remove(2)
  again.toggleRibbon()
  again.toggleRibbon()
  #expect(again.monitors[0].lanes[0].span == 0.5)
}

@Test func windowsAsWideAsTheScreenFanOutOnTheStrip() {
  var w = World()
  w.setMonitors([
    (id: "T", frame: CGRect(x: 0, y: 40, width: 800, height: 1400))
  ])
  w.monitors[0].lanes = (1...5).map { Lane([WindowID($0)]) }
  w.monitors[0].ribbon = true
  w.focused = 1
  w.reveal(inner: inner, outer: outer)
  let f = frames(w)
  let xs = [WindowID(3), 4, 5].map { f[$0]!.minX }
  #expect(Set(xs).count == 3)
  #expect(xs == xs.sorted())
  let edge: CGFloat = 800
  #expect(xs.allSatisfy { $0 < edge }, "each still shows")

  // With a screen past that edge they stay within theirs, where one
  // covers the next.
  var beside = World()
  beside.setMonitors([
    (id: "T", frame: CGRect(x: 0, y: 40, width: 800, height: 1400)),
    (id: "E", frame: CGRect(x: 800, y: 40, width: 800, height: 1400))
  ])
  beside.monitors[0].lanes = (1...5).map { Lane([WindowID($0)]) }
  beside.monitors[0].ribbon = true
  beside.focused = 1
  beside.reveal(inner: inner, outer: outer)
  for (id, r) in frames(beside) { #expect(r.maxX <= edge, "\(id)") }
}

@Test func undoLeavesWhatTheConfigSaysAboutNewScreens() {
  let before = ribbon([[1], [2]], focused: 1)
  var now = before
  now.ribbons = true
  #expect(now.restoring(before).ribbons)
}

@Test func undoBringsARibbonBack() {
  var w = ribbon([[1], [2], [3]], focused: 3)
  w.reveal(inner: inner, outer: outer)
  let before = w
  w.toggleRibbon()
  let back = w.restoring(before)
  #expect(back.monitors[0].ribbon)
  #expect(back.monitors[0].scroll == before.monitors[0].scroll)
}

@Test func aNewWindowOnARibbonIsNeverWrittenAsRows() {
  var w = ribbon([[1, 2]], focused: 1)
  w.place(9, .beside(1))
  #expect(!w.monitors[0].rows)
  #expect(w.monitors[0].lanes.map(\.windows) == [[1, 2], [9]])
}

@Test func theLanguageOfTheConfig() throws {
  #expect(try Config.load(Data(#"{"ribbon": true}"#.utf8)).ribbon)
  #expect(!Config.defaults.ribbon)  // opt-in
  var edited = Config.defaults.raw
  edited.ribbon = true
  let file = try Config.file(for: edited)
  #expect(try Config.load(file).ribbon)
  #expect(try Command.parse("ribbon") == [.ribbon])
  #expect(Command.ribbon.description == "ribbon")
  #expect(
    Config.defaults.modes["tess"]?[KeySpec(key: "g", mods: [])] == [
      .ribbon
    ])
}
