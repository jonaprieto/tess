import CoreGraphics
import Foundation
import Testing
@testable import Layout

@Test func aStackOnARibbonKeepsTheLengthOfItsLongestWindow() {
  var w = World()
  w.setMonitors([
    (id: "A", frame: CGRect(x: 0, y: 40, width: 1800, height: 1129))
  ])
  w.monitors[0].lanes = [Lane([1, 2]), Lane([3])]
  w.monitors[0].ribbon = true
  w.keepRibbon(
    0, order: [1, 2, 3], lengths: [1: 500, 2: 900, 3: 500],
    inner: 10, outer: 10)
  #expect(w.monitors[0].lanes[0].span > w.monitors[0].lanes[1].span)
}

@Test func windowsOverlappingMostOfTheSmallerOneBecomeAnAccordion() {
  for (y1, h1, y2, h2) in [
    (100.0, 200.0, 150.0, 400.0), (100.0, 400.0, 350.0, 200.0)
  ] {
    var w = world([])
    w.rebuild([
      (id: 1, frame: CGRect(x: 10, y: y1, width: 980, height: h1)),
      (id: 2, frame: CGRect(x: 10, y: y2, width: 980, height: h2))
    ])
    #expect(w.monitors[0].lanes[0].accordion)
  }
}

@Test func aDisplayTurningSquareKeepsItsRows() {
  var w = world([])
  w.monitors[0].rows = true
  w.setMonitors([
    (
      id: w.monitors[0].id,
      frame: CGRect(x: 0, y: 0, width: 1000, height: 1000)
    )
  ])
  #expect(w.monitors[0].rows)
}

@Test func growingAgainstNoExtentChangesNothing() {
  #expect(grown([1, 1], at: 0, by: 10, extent: 0) == [1, 1])
}

@Test func aWindowShownEquallyOnTwoScreensGoesToTheFirst() {
  var w = World()
  w.setMonitors([
    (id: "A", frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
    (id: "B", frame: CGRect(x: 1100, y: 0, width: 1000, height: 800))
  ])
  #expect(
    w.monitorIndex(
      for: CGRect(x: 900, y: 100, width: 300, height: 400))
      == 0)
}

@Test func aWindowExactlyAtTheTopOfTheTrayCountsAsOnIt() {
  var w = World()
  w.setMonitors([
    (id: "A", frame: CGRect(x: 0, y: 40, width: 1800, height: 1129))
  ])
  w.monitors[0].ribbon = true
  let top = w.monitors[0].frame.maxY - World.trayDepth - 1
  #expect(
    w.onStrip(0, CGRect(x: 100, y: top, width: 400, height: 300)))
  #expect(
    !w.onStrip(0, CGRect(x: 100, y: top - 1, width: 400, height: 300))
  )
}

// MARK: Screens around a ribbon

private let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let below = CGRect(x: 0, y: 800, width: 1000, height: 800)
private let beside = CGRect(x: 1000, y: 0, width: 1000, height: 800)

/// A ribbon on `a`, the first screen, with `others` around it.
private func around(_ others: [CGRect], lanes: Int = 0) -> World {
  var w = World()
  w.setMonitors(
    [(id: "A", frame: a)]
      + others.enumerated().map {
        (id: "O\($0.offset)", frame: $0.element)
      }
  )
  w.monitors[0].lanes = (0..<lanes).map { Lane([WindowID($0 + 1)]) }
  w.monitors[0].ribbon = true
  w.focused = lanes > 0 ? 1 : nil
  return w
}

private func edge(_ others: [CGRect]) -> ParkEdge {
  around(others).parkEdge(0)
}

@Test func aScreenBelowTakesTheBottomEdgeOnlyIfItOverlapsAlongIt() {
  #expect(edge([]) == .bottom)
  #expect(edge([below]) == .right)
  // Within the point of tolerance.
  #expect(edge([below.offsetBy(dx: 0, dy: -1)]) == .right)
  // Only touching at a corner.
  #expect(edge([below.offsetBy(dx: 1000, dy: 0)]) == .bottom)
  #expect(edge([below.offsetBy(dx: -1000, dy: 0)]) == .bottom)
}

@Test func aScreenBesideTakesTheRightEdgeOnlyIfItOverlapsAlongIt() {
  #expect(edge([below, beside]) == .left)
  #expect(edge([below, beside.offsetBy(dx: -1, dy: 0)]) == .left)
  #expect(edge([below, beside.offsetBy(dx: 0, dy: 800)]) == .right)
  #expect(edge([below, beside.offsetBy(dx: 0, dy: -800)]) == .right)
}

@Test func withNoFreeEdgeTheBottomOneIsUsed() {
  let left = beside.offsetBy(dx: -2000, dy: 0)
  #expect(edge([below, beside, left]) == .bottom)
  #expect(
    edge([below, beside, left.offsetBy(dx: 1, dy: 0)]) == .bottom)
  #expect(edge([below, beside, left.offsetBy(dx: 2, dy: 0)]) == .left)
  #expect(
    edge([below, beside, left.offsetBy(dx: 0, dy: 800)]) == .left)
  #expect(
    edge([below, beside, left.offsetBy(dx: 0, dy: -800)]) == .left)
}

@Test func theBottomStripEndsWhereTheScreenDoes() {
  let w = around([])
  func on(_ x: Double, _ y: Double) -> Bool {
    w.onStrip(0, CGRect(x: x, y: y, width: 100, height: 100))
  }
  #expect(on(100, 799))
  #expect(!on(100, 800))
  #expect(!on(-100, 760))
  #expect(!on(1000, 760))
}

@Test func theRightStripEndsWhereTheScreenDoes() {
  let w = around([below])
  func on(_ x: Double, _ y: Double) -> Bool {
    w.onStrip(0, CGRect(x: x, y: y, width: 100, height: 100))
  }
  #expect(on(979, 100))
  #expect(!on(978, 100))
  #expect(on(999, 100))
  #expect(!on(1000, 100))
  #expect(!on(100, 100))
  #expect(!on(979, 800))
  #expect(!on(979, -100))
}

@Test func theLeftStripEndsWhereTheScreenDoes() {
  let w = around([below, beside])
  func on(_ x: Double, _ y: Double) -> Bool {
    w.onStrip(0, CGRect(x: x, y: y, width: 100, height: 100))
  }
  #expect(on(-79, 100))
  #expect(!on(-78, 100))
  #expect(on(-99, 100))
  #expect(!on(-100, 100))
  #expect(!on(500, 100))
  #expect(!on(-79, 800))
  #expect(!on(-79, -100))
}

@Test func aLeftStripTakesItsDepthOffTheTiledArea() {
  let area = around([below, beside]).tileArea(
    0, inner: 10, outer: 10)
  #expect(area.minX == 30)
  #expect(area.maxX == 990)
}

@Test func parkedWindowsShowTheirEdgeOnTheStripOfTheirSide() throws {
  var right = around([below], lanes: 6)
  right.reveal(inner: 10, outer: 10)
  let parked = right.parked(inner: 10, outer: 10)
  #expect(!parked.isEmpty)
  let frames = right.frames(inner: 10, outer: 10)
  for id in parked {
    #expect(frames[id]?.minX == 980)
  }
  var left = around([below, beside], lanes: 6)
  left.reveal(inner: 10, outer: 10)
  let onLeft = left.parked(inner: 10, outer: 10)
  let there = left.frames(inner: 10, outer: 10)
  for id in onLeft {
    #expect(there[id]?.maxX == 20)
  }
}

@Test func parkedWindowsFanOutToTheEndOfTheStrip() throws {
  var w = around([], lanes: 6)
  w.reveal(inner: 10, outer: 10)
  let area = w.tileArea(0, inner: 10, outer: 10)
  let frames = w.frames(inner: 10, outer: 10)
  let parked = w.parked(inner: 10, outer: 10)
  let ends = parked.compactMap { frames[$0]?.maxX }
  let last = try #require(ends.max())
  #expect(abs(last - area.maxX) <= 1)
}

@Test func onASideAScreenBelowStopsTheFanAtTheBottom() throws {
  var blocked = around([below], lanes: 6)
  blocked.reveal(inner: 10, outer: 10)
  let area = blocked.tileArea(0, inner: 10, outer: 10)
  let frames = blocked.frames(inner: 10, outer: 10)
  let bottoms = blocked.parked(inner: 10, outer: 10).compactMap {
    frames[$0]?.maxY
  }
  let lowest = try #require(bottoms.max())
  #expect(abs(lowest - area.maxY) <= 1)
}

@Test func aFullStepOfScrollIsAMoveAndHalfAPointIsNot() {
  var w = around([], lanes: 6)
  w.focused = 6
  let moved = w.reveal(inner: 10, outer: 10)
  #expect(moved)
  let end = w.monitors[0].scroll
  w.monitors[0].scroll = end + 0.5
  let again = w.reveal(inner: 10, outer: 10)
  #expect(!again)
  #expect(w.monitors[0].scroll == end)
}

@Test func aRibbonKeepsItsOrderByTheFirstWindowOfEachLane() {
  var w = around([])
  w.monitors[0].lanes = [Lane([1]), Lane([2, 3])]
  w.keepRibbon(
    0, order: [3, 1, 2], lengths: [:], inner: 10, outer: 10)
  #expect(w.monitors[0].lanes.map(\.windows) == [[2, 3], [1]])
}

@Test func aLoneLaneOnARibbonKeepsItsSpan() {
  var w = around([])
  w.monitors[0].lanes = [Lane([1])]
  let span = w.monitors[0].lanes[0].span
  w.keepRibbon(0, order: [1], lengths: [1: 300], inner: 10, outer: 10)
  #expect(w.monitors[0].lanes[0].span == span)
}

// MARK: Moving between screens

private func screens(_ rects: [CGRect]) -> World {
  var w = World()
  w.setMonitors(
    rects.enumerated().map {
      (id: "S\($0.offset)", frame: $0.element)
    })
  return w
}

@Test func theNeighborIsTheScreenThatWay() {
  let up = below.offsetBy(dx: 0, dy: -1600)
  let w = screens([
    a, below, up, beside, beside.offsetBy(dx: -2000, dy: 0)
  ])
  #expect(w.neighbor(of: 0, .down) == 1)
  #expect(w.neighbor(of: 0, .up) == 2)
  #expect(w.neighbor(of: 0, .right) == 3)
  #expect(w.neighbor(of: 0, .left) == 4)
}

@Test func nothingThatWayIsNoNeighbor() {
  #expect(screens([a, beside]).neighbor(of: 0, .left) == nil)
  #expect(screens([a, beside]).neighbor(of: 1, .right) == nil)
  #expect(screens([a, below]).neighbor(of: 0, .up) == nil)
  #expect(screens([a, below]).neighbor(of: 1, .down) == nil)
}

@Test func aScreenExactlyDiagonalCountsAsBesideNotAbove() {
  let diagonal = a.offsetBy(dx: 1000, dy: 1000)
  let w = screens([a, diagonal])
  #expect(w.neighbor(of: 0, .right) == 1)
  #expect(w.neighbor(of: 0, .down) == nil)
  #expect(w.neighbor(of: 1, .left) == 0)
  #expect(w.neighbor(of: 1, .up) == nil)
}

@Test func theNearestScreenThatWayWins() {
  let w = screens([
    a, a.offsetBy(dx: 1000, dy: 900), a.offsetBy(dx: 1100, dy: 0)
  ])
  #expect(w.neighbor(of: 0, .right) == 2)
}

@Test func screensCycleForwardAndBackRoundTheEnd() {
  var w = screens([a, beside, beside.offsetBy(dx: 1000, dy: 0)])
  w.cycleMonitor(1)
  #expect(w.activeMonitor == 1)
  w.cycleMonitor(-1)
  w.cycleMonitor(-1)
  #expect(w.activeMonitor == 2)
  var none = World()
  none.cycleMonitor(1)
  #expect(none.activeMonitor == 0)
}

@Test func aSquareScreenIsColumnsAndASideTurnGoesByItsNewShape() {
  let square = CGRect(x: 0, y: 0, width: 1000, height: 1000)
  let tall = CGRect(x: 0, y: 0, width: 800, height: 1200)
  #expect(!Monitor(id: "A", frame: square).rows)
  var w = World()
  w.setMonitors([(id: "A", frame: square)])
  w.setMonitors([(id: "A", frame: tall)])
  #expect(w.monitors[0].rows)
  w.setMonitors([(id: "A", frame: square)])
  #expect(!w.monitors[0].rows)
}

@Test func windowsOfAGoneScreenGoToTheMainOne() {
  var w = world([[1]], [[2]])
  w.setMonitors(
    [left, (id: "C", frame: right.frame)], main: "C")
  #expect(lanes(w, 1) == [[2]])
  #expect(lanes(w, 0) == [[1]])
}

@Test func theActiveScreenStaysWithinTheScreensThereAre() {
  var w = world([], [])
  w.activeMonitor = 1
  w.setMonitors([left])
  #expect(w.activeMonitor == 0)
}

@Test func anotherWindowLeavingKeepsTheFullscreenOne() {
  var w = world([[1], [2]], focused: 1)
  w.monitors[0].fullscreen = 1
  w.detach(2)
  #expect(w.monitors[0].fullscreen == 1)
  w.detach(1)
  #expect(w.monitors[0].fullscreen == nil)
}

@Test func aWindowArrivingAcrossTheLanesGoesToTheEnd() {
  var w = world([[1]])
  w.place(2, on: 0, from: .down)
  #expect(lanes(w) == [[1], [2]])
  w.place(3, on: 0, from: .right)
  #expect(lanes(w) == [[3], [1], [2]])
}

// MARK: Sharing out room

@Test func floorsThatExactlyFitAreKept() {
  #expect(floored([1, 1], [60, 40], whole: 100) == [60, 40])
  #expect(floored([1, 1], [60, 0], whole: 100) == [60, 40])
  #expect(floored([1, 1], [70, 40], whole: 100) == [1, 1])
}

@Test func aPointShortOfAFloorIsLeftAlone() {
  #expect(floored([1, 1], [51, 0], whole: 100) == [1, 1])
  #expect(floored([1, 1], [52, 0], whole: 100) == [52, 48])
}

@Test func growingAWindowWhoseNeighborsHaveNoRoomSharesEvenly() {
  let shares = grown([1, 0, 0], at: 0, by: -20, extent: 100).map {
    ($0 * 100).rounded()
  }
  #expect(shares == [80, 10, 10])
}

@Test func aStackKeepsWhatItsMostDemandingWindowKeeps() {
  var w = world([[1, 2], [3]])
  w.respect(
    [
      1: CGSize(width: 300, height: 0),
      2: CGSize(width: 700, height: 0)
    ],
    inner: 10, outer: 0)
  #expect(w.frames(inner: 10, outer: 0)[1]?.width == 700)
}

// MARK: Dropping a window

private func dropWorld() -> (World, [WindowID: CGRect]) {
  let w = world([[1], [2]])
  return (
    w,
    [
      1: CGRect(x: 0, y: 100, width: 500, height: 400),
      2: CGRect(x: 500, y: 100, width: 500, height: 400)
    ]
  )
}

@Test func overAnotherWindowItIsNotTheOwnPlaceThatCounts() {
  let (w, frames) = dropWorld()
  var overlapping = frames
  overlapping[1] = CGRect(x: 0, y: 100, width: 750, height: 400)
  #expect(
    w.dropZone(
      1, at: CGPoint(x: 700, y: 300), frames: overlapping)
      == .swap(2))
  #expect(
    w.dropZone(1, at: CGPoint(x: 100, y: 300), frames: overlapping)
      == .stay)
}

@Test func twelvePointsOffAWindowStillCounts() {
  let (w, frames) = dropWorld()
  #expect(
    w.dropZone(1, at: CGPoint(x: 700, y: 88), frames: frames) != .stay
  )
  #expect(
    w.dropZone(1, at: CGPoint(x: 700, y: 87), frames: frames) == .stay
  )
}

@Test func theTopAndBottomOfAWindowGoByItsOwnFrame() {
  let (w, frames) = dropWorld()
  #expect(
    w.dropZone(1, at: CGPoint(x: 750, y: 120), frames: frames)
      == .stack(2, after: false))
  #expect(
    w.dropZone(1, at: CGPoint(x: 750, y: 480), frames: frames)
      == .stack(2, after: true))
}

@Test func exactlyAQuarterInIsStillAnEdge() {
  let (w, frames) = dropWorld()
  #expect(
    w.dropZone(1, at: CGPoint(x: 625, y: 300), frames: frames)
      == .lane(2, after: false))
}

@Test func onTheDiagonalOfACornerTheSidesWin() {
  let (w, frames) = dropWorld()
  #expect(
    w.dropZone(1, at: CGPoint(x: 550, y: 140), frames: frames)
      == .lane(2, after: false))
}

// MARK: Warnings about a place

@Test func aWindowIsWarnedAboutOnlyIfItWouldGetSmaller() throws {
  let w = world([[1], [2], [3]], focused: 1)
  var preview = w
  preview.place(3, .replace(1))
  let frame = try #require(preview.frames(inner: 10, outer: 10)[1])
  func warned(_ size: CGSize) -> [WindowID] {
    w.placementWarnings(
      3, at: .replace(1), sizes: [1: size], inner: 10, outer: 10)
  }
  #expect(warned(frame.size).isEmpty)
  #expect(
    warned(CGSize(width: frame.width + 1, height: 0)).isEmpty)
  #expect(
    warned(CGSize(width: 0, height: frame.height + 1)).isEmpty)
  #expect(
    warned(CGSize(width: frame.width + 2, height: 0)) == [1])
  #expect(
    warned(CGSize(width: 0, height: frame.height + 2)) == [1])
}

@Test func aWindowThatStaysPutIsNotWarnedAboutButThePickedOneIs() {
  let w = world([[1], [2], [3]], focused: 1)
  let big = CGSize(width: 5000, height: 5000)
  #expect(
    w.placementWarnings(
      3, at: .replace(1), sizes: [2: big], inner: 10, outer: 10
    ).isEmpty)
  #expect(
    w.placementWarnings(
      3, at: .replace(1), sizes: [3: big], inner: 10, outer: 10)
      == [3])
}

// MARK: Fuzzy matching

@Test func caseIsIgnoredRightUpToTheEndsOfTheAlphabet() {
  #expect(fuzzyScore("a", "A") != nil)
  #expect(fuzzyScore("z", "Z") != nil)
  #expect(fuzzyScore("A", "a") != nil)
}

@Test func onlyLettersBeforeAMatchKeepItFromStartingAWord() {
  for text in ["Ab", "Zb", "ab", "zb"] {
    #expect(fuzzyScore("b", text) == 1, "\(text)")
  }
  for text in ["@b", "[b", "`b", "{b"] {
    #expect(fuzzyScore("b", text) == 3, "\(text)")
  }
}

@Test func aHumpOnlyStartsAfterALowercaseLetter() {
  #expect(fuzzyScore("a", "bA") == 3)
  #expect(fuzzyScore("z", "aZ") == 3)
  #expect(fuzzyScore("b", "aB") == 3)
  #expect(fuzzyScore("b", "zB") == 3)
  #expect(fuzzyScore("b", "aBC") == 3)
  #expect(fuzzyScore("b", "aB{") == 3)
  #expect(fuzzyScore("b", "@B") == 3)
  #expect(fuzzyScore("b", "AB") == 1)
  #expect(fuzzy("b", "aBCé")?.score == 3)
}

@Test func theWholeQueryCountsWhenItScoresHigherThanItsWords() {
  #expect(fuzzyWords("a b", "a b") == 13)
}

// MARK: Rects

@Test func nearMeansWithinAPointWhereverTheRectIs() {
  let r = CGRect(x: 100, y: 200, width: 300, height: 400)
  #expect(r.isNear(r))
  #expect(r.isNear(r.offsetBy(dx: 1, dy: 1)))
  #expect(!r.isNear(r.offsetBy(dx: 2, dy: 0)))
  #expect(!r.isNear(r.offsetBy(dx: 0, dy: 2)))
  let wider = CGRect(x: 100, y: 200, width: 301, height: 401)
  #expect(r.isNear(wider))
  #expect(!r.isNear(CGRect(x: 100, y: 200, width: 302, height: 400)))
}

@Test func aWindowIsLostOnlyBelowATenthOnItsBestScreen() {
  let far = beside.offsetBy(dx: 5000, dy: 0)
  let r = CGRect(x: 900, y: 0, width: 1000, height: 100)
  #expect(!r.isLost(on: [far, a]))
  #expect(!r.isLost(on: [a, far]))
  #expect(r.isLost(on: [far]))
  let sliver = CGRect(x: 991, y: 0, width: 1000, height: 100)
  #expect(sliver.isLost(on: [a]))
}

@Test func aScreenSmallerThanItsGapsHoldsNoWindow() {
  var w = World()
  w.setMonitors([
    (id: "A", frame: CGRect(x: 0, y: 0, width: 20, height: 800))
  ])
  w.monitors[0].lanes = [Lane([1])]
  #expect(w.frames(inner: 10, outer: 10).isEmpty)
}

@Test func halfAWindowsLengthInCommonIsTheSameLane() {
  var w = world([])
  w.rebuild([
    (id: 1, frame: CGRect(x: 0, y: 10, width: 100, height: 300)),
    (id: 2, frame: CGRect(x: 50, y: 400, width: 100, height: 300))
  ])
  #expect(lanes(w) == [[1, 2]])
}

@Test func exactlyHalfOverTheSmallerOneIsNotAPile() {
  var w = world([])
  w.rebuild([
    (id: 1, frame: CGRect(x: 10, y: 0, width: 980, height: 400)),
    (id: 2, frame: CGRect(x: 10, y: 200, width: 980, height: 400))
  ])
  #expect(!w.monitors[0].lanes[0].accordion)
}

@Test func aWindowBetweenScreensGoesToTheOneShowingMostOfIt() {
  let w = screens([a, a.offsetBy(dx: 1100, dy: 0)])
  #expect(
    w.monitorIndex(
      for: CGRect(x: 950, y: 100, width: 400, height: 400)) == 1)
  // A tenth of it, on the dot.
  #expect(
    w.monitorIndex(
      for: CGRect(x: 910, y: 100, width: 900, height: 400)) != nil)
  #expect(
    w.monitorIndex(for: CGRect(x: 1050, y: 100, width: 0, height: 0))
      == nil)
}

// MARK: Words

@Test func aParsedFormulaSubtracts() {
  #expect(Parse.arithmetic("5-3") == 2)
}

@Test func onlyNumbersBelowAQuadrillionShowWhole() {
  #expect(Parse.number(1e15) == "1e+15")
  #expect(Parse.number(123) == "123")
}

@Test func theWifiDeviceIsTheLineRightAfterItsPort() {
  #expect(Parse.wifiDevice("Hardware Port: Wi-Fi") == nil)
  #expect(
    Parse.wifiDevice("Device: en1\nHardware Port: Wi-Fi\nx") == nil)
  #expect(
    Parse.wifiDevice("Hardware Port: Wi-Fi\nDevice: en0") == "en0")
}

@Test func twoAuthorsNeedNoEtAl() {
  let two = Parse.Paper(
    id: "1", title: "T", authors: ["A B", "C D"], year: "2020")
  #expect(!two.detail.contains("et al."))
  let three = Parse.Paper(
    id: "1", title: "T", authors: ["A", "B", "C"], year: "2020")
  #expect(three.detail.contains("et al."))
}

@Test func commandEdgesParseAndPrint() throws {
  #expect(Command.volume(.step(0)).description.hasSuffix("+0"))
  #expect(try Command.parse("focus-tab 0") == [.focusTab(0)])
  #expect(throws: (any Error).self) {
    try Command.parse("caffeine 0")
  }
}

@Test func zeroCountsAsTheForwardWord() {
  func label(_ c: Command) -> String? { Command.label(of: [c]) }
  #expect(label(.resize(.width, 0)) == L("Wider"))
  #expect(label(.resize(.height, 0)) == L("Taller"))
  #expect(label(.grow(0)) == L("Bigger"))
  #expect(label(.volume(.step(0))) == L("Louder"))
  #expect(label(.cycleMonitor(0)) == L("Previous screen"))
  #expect(label(.cycleWindow(0)) == L("Previous window"))
  #expect(label(.caffeine(0)) == L("Let the Mac sleep"))
  #expect(label(.caffeine(30)) == L("Keep awake for 30 min"))
  #expect(label(.mode("main")) == L("Back"))
  #expect(label(.mode("back")) == L("Back"))
  #expect(label(.mode("tess")) != L("Back"))
}

@Test func turningJevOnIsSaved() throws {
  var edited = Config.defaults.raw
  edited.jev = true
  #expect(try Config.load(Config.file(for: edited)).jev)
}
