import CoreGraphics
import Testing
@testable import Layout

@Test func pickerWarnsWhenPlacementSqueezesAKnownWindow() {
  let w = world([[1], [2]], [], focused: 1)
  let sizes: [WindowID: CGSize] = [2: CGSize(width: 450, height: 0)]
  #expect(
    w.placementWarnings(
      9, at: .beside(1), sizes: sizes, inner: 0, outer: 0) == [2])
  #expect(
    w.placementWarnings(
      9, at: .replace(1), sizes: sizes, inner: 0, outer: 0
    ).isEmpty)
  #expect(
    w.placementWarnings(
      9, at: .monitor(1), sizes: sizes, inner: 0, outer: 0
    ).isEmpty)
  #expect(
    w.placementWarnings(
      9, at: .float, sizes: sizes, inner: 0, outer: 0
    ).isEmpty)
  #expect(lanes(w) == [[1], [2]])
}

@Test func pickerChecksBothSidesOfASwapAndAllowsUnknownSizes() {
  var w = world([[1], [2, 3]], [], focused: 1)
  w.monitors[0].lanes[0].size = 2
  let sizes: [WindowID: CGSize] = [
    1: CGSize(width: 600, height: 600),
    2: CGSize(width: 0, height: 600)
  ]
  #expect(
    w.placementWarnings(
      1, at: .replace(2), sizes: sizes, inner: 0, outer: 0) == [1])
  #expect(
    w.placementWarnings(
      1, at: .replace(2), sizes: [:], inner: 0, outer: 0
    ).isEmpty)
  #expect(
    w.placementWarnings(
      2, at: .replace(1), sizes: sizes, inner: 0, outer: 0) == [1])
}

@Test func replaceSwapsTwoTiledWindows() {
  var w = world([[1, 2], [3]], [[4]], focused: 1)
  w.place(4, .replace(2))
  #expect(lanes(w) == [[1, 4], [3]])
  #expect(lanes(w, 1) == [[2]])
  #expect(w.focused == 4)
}

@Test
func
  replaceWithANewWindowSharesThePlaceOfTheOtherAndNoOneElseGivesUpRoom()
{
  var w = world([[1, 2], [3]], focused: 1)
  let before = w.frames(inner: 0, outer: 0)
  w.place(9, .replace(2))
  #expect(lanes(w) == [[1, 9, 2], [3]])
  #expect(w.focused == 9)
  let after = w.frames(inner: 0, outer: 0)
  #expect(after[1] == before[1])
  #expect(after[3] == before[3])
  #expect(after[2]?.height == before[2].map { $0.height / 2 })
  w.floating.insert(8)
  w.place(8, .replace(3))
  #expect(lanes(w) == [[1, 9, 2], [8, 3]])
  #expect(w.floating.isEmpty)

  // A window alone on its screen has only the other way to go.
  var alone = world([[1]], focused: 1)
  alone.place(9, .replace(1))
  #expect(lanes(alone) == [[9], [1]])
}

@Test func aNewWindowSplitsOnlyThePlaceOfAWindowStackedInTheOnlyLane()
{
  for spot in [Spot.replace(1), .beside(1), .here] {
    var w = world([[1, 2]], focused: 1)
    let below = w.frames(inner: 10, outer: 10)[2]
    w.place(9, spot)
    let f = w.frames(inner: 10, outer: 10)
    #expect(f[2] == below, "\(spot)")
    #expect(f[9]?.height == f[1]?.height, "\(spot)")
    #expect(f[1]?.width == f[9]?.width, "\(spot)")
    #expect(w.focused == 9, "\(spot)")
  }
  var taking = world([[1, 2]], focused: 1)
  taking.place(9, .replace(1))
  #expect(lanes(taking) == [[9, 1], [2]])
  var beside = world([[1, 2]], focused: 2)
  beside.place(9, .beside(2))
  #expect(lanes(beside) == [[1], [2, 9]])

  // How tall each window was stays with it.
  var sized = world([[1, 2]], focused: 1)
  sized.monitors[0].lanes[0].sizes = [3, 1]
  let tall = sized.frames(inner: 0, outer: 0)[1]?.height
  sized.place(9, .beside(1))
  #expect(sized.frames(inner: 0, outer: 0)[1]?.height == tall)
}

@Test func besideMakesANewLaneRightOfTheTarget() {
  var w = world([[1], [2, 3]], [[4]], focused: 1)
  w.place(4, .beside(2))
  #expect(lanes(w) == [[1], [2, 3], [4]])
  #expect(lanes(w, 1).isEmpty)
  w.place(1, .beside(3))
  #expect(lanes(w) == [[2, 3], [1], [4]])
  w.place(3, .beside(3))
  #expect(lanes(w) == [[2, 3], [1], [4]])
}

@Test func hereGoesNextToTheFocusedWindow() {
  var w = world([[1], [2]], [[4]], focused: 1)
  w.place(4, .here)
  #expect(lanes(w) == [[1], [4], [2]])
  #expect(w.focused == 4)
  w.focused = 1
  w.place(1, .here)
  #expect(lanes(w) == [[1], [4], [2]])
}

@Test func monitorAppendsAtTheRightEnd() {
  var w = world([[1], [2]], [[4]], focused: 1)
  w.place(1, .monitor(1))
  #expect(lanes(w) == [[2]])
  #expect(lanes(w, 1) == [[4], [1]])
  #expect(w.activeMonitor == 1)
  w.place(7, .monitor(5))
  #expect(!w.contains(7))
}

@Test func slotFillsTheGapOfAClosedWindow() {
  var w = world([[1], [2, 3, 4]], focused: 3)
  let s = w.slot(of: 3)!
  w.remove(3)
  w.place(9, .slot(s.position, alone: s.alone))
  #expect(lanes(w) == [[1], [2, 9, 4]])

  w = world([[1], [2], [3]], focused: 2)
  let t = w.slot(of: 2)!
  #expect(t.alone)
  w.remove(2)
  w.place(9, .slot(t.position, alone: t.alone))
  #expect(lanes(w) == [[1], [9], [3]])
}

@Test func floatTakesAWindowOutOfTheLayout() {
  var w = world([[1], [2]], focused: 2)
  w.place(2, .float)
  #expect(lanes(w) == [[1]])
  #expect(w.floating == [2])
}

@Test func labelsFollowMonitorsLanesAndStacks() {
  let w = world([[1, 2], [3]], [[4]])
  let l = stableLabels([:], windows: w.tiled, alphabet: "asd")
  #expect(l == [1: "a", 2: "s", 3: "d"])
}

@Test func fuzzyMatchesSubsequencesBestFirst() {
  #expect(fuzzyScore("brv", "Brave Browser") != nil)
  #expect(fuzzyScore("xyz", "Brave Browser") == nil)
  #expect(fuzzyScore("", "anything") == 0)
  let github = fuzzyScore("gh", "GitHub")!
  let gather = fuzzyScore("gh", "gather")!
  #expect(github > gather)
  #expect(
    fuzzyScore("cal", "Calendar")! > fuzzyScore("cal", "Musical")!)
}

@Test func fuzzyPositionsMarkTheMatchedCharacters() {
  #expect(fuzzyPositions("cal", "Calendar") == [0, 1, 2])
  #expect(fuzzyPositions("gh", "GitHub") == [0, 3])
  #expect(fuzzyPositions("zz", "GitHub") == nil)
  #expect(fuzzyPositions("", "GitHub") == [])
}

@Test func asciiFastPathScoresLikeTheGeneralOne() {
  let texts = [
    "GitHub", "gather", "Calendar", "Musical", "Brave Browser",
    "anoma-log", "pull/42 · github.com", "x"
  ]
  for q in ["gh", "cal", "brv", "an", "pg", "zz", ""] {
    for t in texts {
      #expect(fuzzyScore(q, t) == fuzzy(q, t)?.score, "\(q) in \(t)")
    }
  }
}

@Test func dropZonesSplitAlongOrAcrossTheLanes() {
  // Lanes [1][2] on A (columns, 500 wide), nothing on B.
  var w = world([[1], [2]], [], focused: 2)
  let f = w.frames(inner: 0, outer: 0)
  func zone(_ x: Double, _ y: Double) -> DropZone? {
    w.dropZone(2, at: CGPoint(x: x, y: y), frames: f)
  }
  #expect(zone(20, 400) == .lane(1, after: false))
  #expect(zone(480, 400) == .lane(1, after: true))
  #expect(zone(250, 20) == .stack(1, after: false))
  #expect(zone(250, 780) == .stack(1, after: true))
  #expect(zone(250, 400) == .swap(1))
  #expect(zone(750, 400) == .stay)  // over its own place
  #expect(zone(1500, 400) == .screen(1))
  w.drop(2, .stack(1, after: true))
  #expect(lanes(w) == [[1, 2]] && w.focused == 2)
  w.drop(2, .lane(1, after: false))
  #expect(lanes(w) == [[2], [1]])
  w.drop(2, .swap(1))
  #expect(lanes(w) == [[1], [2]])
  w.drop(2, .screen(1))
  #expect(lanes(w) == [[1]] && lanes(w, 1) == [[2]])
  // Rows: top and bottom edges split along the lanes.
  w.monitors[0].rows = true
  w.monitors[0].lanes = [Lane([1]), Lane([3])]
  let g = w.frames(inner: 0, outer: 0)
  #expect(
    w.dropZone(3, at: CGPoint(x: 500, y: 10), frames: g)
      == .lane(1, after: false))
  #expect(
    w.dropZone(3, at: CGPoint(x: 10, y: 200), frames: g)
      == .stack(1, after: false))
}

@Test func theGapBesideAWindowCountsAsThatWindow() {
  // 1 and 2 with a 10 point gap between them; the mouse in the gap is
  // at 1's right edge.
  let w = world([[1], [2]], [], focused: 2)
  let f = w.frames(inner: 10, outer: 10)
  let gap = CGPoint(x: (f[1]!.maxX + f[2]!.minX) / 2, y: 400)
  #expect(!f[1]!.contains(gap) && !f[2]!.contains(gap))
  var moved = w
  moved.monitors[0].lanes = [Lane([1]), Lane([3]), Lane([2])]
  let g = moved.frames(inner: 10, outer: 10)
  // in the gap, nearer 1
  let between = CGPoint(x: g[1]!.maxX + 2, y: 400)
  #expect(
    moved.dropZone(2, at: between, frames: g) == .lane(1, after: true)
  )
  #expect(
    w.dropZone(2, at: CGPoint(x: 2500, y: 400), frames: f) == nil)
}

@Test func windowsSharingAPlaceDropOnTheFrontOne() {
  // An accordion of 2 and 3 on A: they share one rect, and whichever
  // is in front counts.
  var w = world([[1], [2, 3]], [], focused: 1)
  w.monitors[0].lanes[1].accordion = true
  let f = w.frames(inner: 0, outer: 0)
  let middle = CGPoint(x: 750, y: 400)
  #expect(
    w.dropZone(1, at: middle, frames: f, front: [3, 2]) == .swap(3))
  #expect(
    w.dropZone(1, at: middle, frames: f, front: [2, 3]) == .swap(2))
}

@Test func aRestartKeepsTessFullscreen() {
  // 2 fills monitor A edge to edge, in front of 1 and 3.
  var w = world([], [], focused: nil)
  let a = w.monitors[0].frame
  w.rebuild([
    (
      1,
      CGRect(x: a.minX + 10, y: a.minY + 10, width: 480, height: 780)
    ),
    (
      3,
      CGRect(x: a.minX + 510, y: a.minY + 10, width: 480, height: 780)
    ),
    (2, a)
  ])
  #expect(lanes(w) == [[1], [3], [2]])
  #expect(w.monitors[0].fullscreen == 2)
  // Alone on its monitor (no outer gap), a window filling it is not
  // fullscreen.
  var lone = world([], [], focused: nil)
  lone.rebuild([(5, lone.monitors[1].frame)])
  #expect(
    lanes(lone, 1) == [[5]] && lone.monitors[1].fullscreen == nil)
}

@Test func wordsMatchInAnyOrder() {
  let title = "Brave Browser Alex (DM) - Acme - Slack"
  #expect(fuzzyScore("slack alex", title) == nil)
  #expect(fuzzyWords("slack alex", title) != nil)
  #expect(fuzzyWords("slack zebra", title) == nil)
  // One word is plain fuzzy matching.
  #expect(fuzzyWords("slk", title) == fuzzyScore("slk", title))
  #expect(!Config.defaults.jev)
}

@Test func titlesSplitIntoPartsWithoutTheAppsName() {
  #expect(
    titleParts("Alex (DM) - Acme - 1 new item - Slack", app: "Slack")
      == ["Alex (DM)", "Acme", "1 new item"])
  #expect(
    titleParts("Blog — vveiln ✨ - Brave", app: "Brave Browser") == [
      "Blog", "vveiln ✨"
    ])
  #expect(
    titleParts("main.swift — tess — Visual Studio Code", app: "Code")
      == ["main.swift", "tess"])
  #expect(titleParts("Slack", app: "Slack").isEmpty)
}

@Test func clickLabelsAreOneLetterWhileThereAreEnough() {
  #expect(hintLabels(3, alphabet: "asd") == ["a", "s", "d"])
  #expect(
    hintLabels(5, alphabet: "asd") == ["aa", "as", "ad", "sa", "ss"])
  #expect(hintLabels(0, alphabet: "asd").isEmpty)
}

@Test func clickModeParsesAndPrints() throws {
  #expect(try Command.parse("click") == [.click])
  #expect(try Command.parse("click-key a") == [.clickKey("a")])
  #expect(Command.clickKey("esc").description == "click-key esc")
}
